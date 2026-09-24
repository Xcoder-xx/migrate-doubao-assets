ObjC.import("Foundation");

const fileManager = $.NSFileManager.defaultManager;
const utf8 = $.NSUTF8StringEncoding;

const systemReminderPattern =
  /^(?:\s*<system-reminder(?:\s[^>]*)?>[\s\S]*?<\/system-reminder>\s*)+/;
const imageLocalPathPattern =
  /<image_local_path(?:\s[^>]*)?>([\s\S]*?)<\/image_local_path>/gi;
const inlineImageReferencePrefixPattern = /@image#\d+:/g;
const inlineQuotedFileReferencePattern =
  /@(["'])((?:\/|[A-Za-z]:[\\/])[^\r\n]*?)\1/g;
const inlineFileReferencePattern = /@((?:\/|[A-Za-z]:[\\/])[^\s<]+)/g;
const qwenworkStructuredReferencePattern =
  /@\[(?:mcp-server|image|file):[^\]]+\]\s*/g;
const qwenworkDatabaseImagePattern = /@\[image:base64:([^\]]+)\]\s*/g;
const qwenworkDatabaseFilePattern = /@\[file:external:([^\]]+)\]\s*/g;
const qwenworkReflectionMarkers = [
  "Target file this round:",
  "Full MEMORY.md entries (indexed):",
  "Full USER.md entries (indexed):",
  "Please reflect and reorganize the target file."
];

function fail(message) {
  throw new Error(message);
}

function readUtf8(path) {
  const data = $.NSData.dataWithContentsOfFile(path);
  if (!data) {
    fail("Cannot read source: " + path);
  }
  const value = $.NSString.alloc.initWithDataEncoding(data, utf8);
  if (!value) {
    fail("Source is not valid UTF-8: " + path);
  }
  return ObjC.unwrap(value);
}

function writeUtf8(path, value) {
  const data = $(value).dataUsingEncoding(utf8);
  if (!data.writeToFileAtomically(path, true)) {
    fail("Cannot write temporary session file: " + path);
  }
}

function parseJsonl(path) {
  const text = readUtf8(path);
  if (text === "") {
    return [];
  }
  const lines = text.endsWith("\n")
    ? text.slice(0, -1).split("\n")
    : text.split("\n");
  return lines.map(function (line, index) {
    if (line.endsWith("\r")) {
      line = line.slice(0, -1);
    }
    if (line === "") {
      fail("Blank JSONL line at " + path + ":" + (index + 1));
    }
    const value = JSON.parse(line);
    if (value === null || Array.isArray(value) || typeof value !== "object") {
      fail("Non-object JSONL value at " + path + ":" + (index + 1));
    }
    return value;
  });
}

function sessionIdFrom(records, path) {
  const ids = {};
  records.forEach(function (record) {
    if (typeof record.sessionId === "string" && record.sessionId !== "") {
      ids[record.sessionId] = true;
    }
  });
  const values = Object.keys(ids);
  if (values.length !== 1) {
    fail("Expected one session ID in " + path);
  }
  return values[0];
}

function normalizeTimestamp(value) {
  if (typeof value === "string") {
    return value;
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return new Date(value).toISOString();
  }
  return "";
}

function normalizeDatabaseTimestamp(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return new Date(value < 100000000000 ? value * 1000 : value).toISOString();
  }
  return normalizeTimestamp(value);
}

function timestampMilliseconds(value, label) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value !== "string" || value.trim() === "") {
    fail(label + " is missing");
  }
  const trimmed = value.trim();
  if (/^-?\d+$/.test(trimmed)) {
    const milliseconds = Number(trimmed);
    if (Number.isSafeInteger(milliseconds)) {
      return milliseconds;
    }
  }
  const milliseconds = Date.parse(trimmed);
  if (!Number.isFinite(milliseconds)) {
    fail(label + " is not a valid ISO 8601 or Unix millisecond timestamp: " + value);
  }
  return milliseconds;
}

function compareSessionsByUpdatedAt(left, right) {
  return left.updatedAt.localeCompare(right.updatedAt) ||
    left.sessionId.localeCompare(right.sessionId);
}

function contentTexts(record, acceptedTypes) {
  let content = record.content;
  if (!Array.isArray(content) && record.message) {
    content = record.message.content;
  }
  if (!Array.isArray(content)) {
    return [];
  }
  return content.filter(function (item) {
    return item &&
      acceptedTypes.indexOf(item.type) !== -1 &&
      typeof item.text === "string";
  }).map(function (item) {
    return item.text;
  });
}

function stripSystemReminders(text) {
  return text.replace(systemReminderPattern, "").trim();
}

function isWorkbuddyMetaMessage(record) {
  return record.role === "user" &&
    record.providerData &&
    record.providerData.isMeta === true;
}

function isQwenworkReflectionPrompt(text) {
  return qwenworkReflectionMarkers.every(function (marker) {
    return text.indexOf(marker) !== -1;
  });
}

function decodeXmlText(value) {
  return value
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function baseName(path) {
  const segments = path.split(/[\\/]/);
  return segments[segments.length - 1];
}

function replaceAllLiteral(value, search, replacement) {
  if (search === "") {
    return value;
  }
  return value.split(search).join(replacement);
}

function fileExists(path) {
  const isDirectory = Ref();
  return fileManager.fileExistsAtPathIsDirectory(path, isDirectory) &&
    !isDirectory[0];
}

function runProcess(launchPath, argumentsList) {
  const task = $.NSTask.alloc.init;
  const outputPipe = $.NSPipe.pipe;
  task.launchPath = launchPath;
  task.arguments = argumentsList;
  task.standardOutput = outputPipe;
  task.standardError = outputPipe;
  task.launch;
  const data = outputPipe.fileHandleForReading.readDataToEndOfFile;
  task.waitUntilExit;
  const output = $.NSString.alloc.initWithDataEncoding(data, utf8);
  const text = output ? ObjC.unwrap(output) : "";
  return {
    status: Number(task.terminationStatus),
    output: text
  };
}

function sqliteRows(path, sql) {
  if (!fileExists(path)) {
    return [];
  }
  const result = runProcess("/usr/bin/sqlite3", [
    "-readonly",
    "-json",
    path,
    sql
  ]);
  if (result.status !== 0) {
    fail("Cannot read session metadata database " + path + ": " +
      result.output.trim());
  }
  const text = result.output.trim();
  return text ? JSON.parse(text) : [];
}

function workbuddySessionMetadata() {
  const home = ObjC.unwrap($.NSHomeDirectory());
  const databasePath = home + "/.workbuddy/workbuddy.db";
  if (!fileExists(databasePath)) {
    fail("WorkBuddy session database not found: " + databasePath);
  }
  const rows = sqliteRows(
    databasePath,
    "SELECT id, COALESCE(NULLIF(custom_title, ''), NULLIF(title, '')) " +
      "AS title, created_at, updated_at, cwd, is_playground FROM sessions " +
      "WHERE deleted_at IS NULL " +
      "ORDER BY updated_at, id"
  );
  const sessions = {};
  rows.forEach(function (row) {
    if (typeof row.id === "string" && row.id) {
      sessions[row.id] = {
        title: typeof row.title === "string" ? row.title.trim() : "",
        startedAt: normalizeDatabaseTimestamp(row.created_at),
        updatedAt: normalizeDatabaseTimestamp(row.updated_at),
        cwd: typeof row.cwd === "string" ? row.cwd.replace(/[\\/]+$/, "") : "",
        isWorkspace: row.is_playground === 0
      };
    }
  });
  return sessions;
}

function mergeAttachments(left, right) {
  const seen = {};
  return (left || []).concat(right || []).filter(function (attachment) {
    if (!attachment || seen[attachment.absPath]) {
      return false;
    }
    seen[attachment.absPath] = true;
    return true;
  });
}

function decodeBase64Utf8(value) {
  const remainder = value.length % 4;
  const padded = remainder === 0
    ? value
    : value + "=".repeat(4 - remainder);
  const data = $.NSData.alloc.initWithBase64EncodedStringOptions($(padded), 0);
  if (!data) {
    return "";
  }
  const decoded = $.NSString.alloc.initWithDataEncoding(data, utf8);
  return decoded ? ObjC.unwrap(decoded) : "";
}

function qwenworkDatabaseAttachments(row, parts) {
  let metadata = {};
  try {
    metadata = JSON.parse(row.metadata || "{}");
  } catch (_) {
    metadata = {};
  }
  const identifier =
    typeof metadata.sdkMessageUuid === "string" && metadata.sdkMessageUuid
      ? metadata.sdkMessageUuid
      : row.message_id;
  const attachments = [];

  parts.forEach(function (part) {
    if (part && part.type === "text" && typeof part.text === "string") {
      qwenworkDatabaseImagePattern.lastIndex = 0;
      let match;
      while ((match = qwenworkDatabaseImagePattern.exec(part.text)) !== null) {
        const path = decodeBase64Utf8(match[1]);
        if (path && fileExists(path)) {
          attachments.push({
            name: baseName(path),
            absPath: path,
            identifier: identifier
          });
        }
      }
      qwenworkDatabaseFilePattern.lastIndex = 0;
      while ((match = qwenworkDatabaseFilePattern.exec(part.text)) !== null) {
        const path = match[1];
        if (fileExists(path)) {
          attachments.push({
            name: baseName(path),
            absPath: path,
            identifier: identifier
          });
        }
      }
    }

    const toolName = part && typeof part.toolName === "string"
      ? part.toolName
      : "";
    if (
      !part ||
      (
        part.type !== "tool_use" &&
        !String(part.type || "").endsWith("qwenwork_file_present_files")
      ) ||
      (
        toolName !== "present_files" &&
        !toolName.endsWith("qwenwork_file_present_files")
      ) ||
      !part.input ||
      !Array.isArray(part.input.files)
    ) {
      return;
    }
    part.input.files.forEach(function (file) {
      const path = typeof file === "string"
        ? file
        : file && typeof file.file_path === "string"
          ? file.file_path
          : "";
      if (path && fileExists(path)) {
        attachments.push({
          name: baseName(path),
          absPath: path,
          identifier: identifier
        });
      }
    });
  });

  return mergeAttachments([], attachments);
}

function qwenworkDatabaseSessions() {
  const home = ObjC.unwrap($.NSHomeDirectory());
  const databasePath =
    home + "/Library/Application Support/QwenWorkCN/data/agents.db";
  if (!fileExists(databasePath)) {
    fail("QwenWork session database not found: " + databasePath);
  }
  const rows = sqliteRows(
    databasePath,
    "WITH task_runs AS (" +
      "SELECT task_id, chat_id, sub_chat_id, run_at, " +
        "ROW_NUMBER() OVER (" +
          "PARTITION BY sub_chat_id ORDER BY run_at DESC, id DESC" +
        ") AS run_rank " +
      "FROM task_run_logs WHERE sub_chat_id IS NOT NULL" +
    ") " +
    "SELECT sc.session_id AS id, " +
      "COALESCE(NULLIF(sc.name, ''), NULLIF(c.name, '')) AS title, " +
      "lp.id AS local_project_id, lp.name AS local_project_name, " +
      "tr.task_id AS scheduled_task_id, " +
      "tr.run_at AS scheduled_run_at, " +
      "sc.created_at AS session_created_at, " +
      "sc.updated_at AS session_updated_at, m.sequence, m.message_id, " +
      "m.role, m.parts, m.metadata, m.created_at AS message_created_at " +
      "FROM sub_chats sc JOIN chats c ON c.id = sc.chat_id " +
      "LEFT JOIN local_projects lp ON lp.id = c.local_project_id " +
        "AND lp.deleted_at IS NULL " +
      "LEFT JOIN task_runs tr ON tr.sub_chat_id = sc.id " +
        "AND tr.chat_id = c.id AND tr.run_rank = 1 " +
      "LEFT JOIN messages m ON m.sub_chat_id = sc.id " +
      "WHERE sc.session_id IS NOT NULL " +
      "ORDER BY sc.updated_at, sc.session_id, m.sequence"
  );
  const byId = {};
  rows.forEach(function (row) {
    if (typeof row.id !== "string" || !row.id) {
      return;
    }
    if (!byId[row.id]) {
      byId[row.id] = {
        sessionId: row.id,
        sourcePath: databasePath,
        title: typeof row.title === "string" ? row.title.trim() : "",
        startedAt: normalizeDatabaseTimestamp(row.session_created_at),
        updatedAt: normalizeDatabaseTimestamp(row.session_updated_at),
        projectId: typeof row.local_project_id === "string"
          ? row.local_project_id
          : "",
        projectName: typeof row.local_project_name === "string"
          ? row.local_project_name.trim()
          : "",
        projectDescription: "",
        scheduledTaskId: typeof row.scheduled_task_id === "string"
          ? row.scheduled_task_id
          : "",
        scheduledRunAt: typeof row.scheduled_run_at === "number"
          ? row.scheduled_run_at
          : 0,
        messages: []
      };
    }
    if (
      (row.role !== "user" && row.role !== "assistant") ||
      typeof row.parts !== "string"
    ) {
      return;
    }
    let parts;
    try {
      parts = JSON.parse(row.parts);
    } catch (_) {
      fail("Invalid QwenWork message parts for " + row.id);
    }
    if (!Array.isArray(parts)) {
      fail("Invalid QwenWork message parts for " + row.id);
    }
    const attachments = qwenworkDatabaseAttachments(row, parts);
    let metadata = {};
    try {
      metadata = JSON.parse(row.metadata || "{}");
    } catch (_) {
      metadata = {};
    }
    const finalTextId =
      row.role === "assistant" &&
      typeof metadata.finalTextId === "string"
        ? metadata.finalTextId
        : null;
    const texts = parts.filter(function (part) {
      return part &&
        part.type === "text" &&
        typeof part.text === "string" &&
        (row.role === "user" || part.id === finalTextId);
    }).map(function (part) {
      return part.text;
    });
    const content = stripSystemReminders(texts.join("\n\n"))
      .replace(qwenworkStructuredReferencePattern, "")
      .trim();
    if (
      row.role === "user" &&
      content &&
      isQwenworkReflectionPrompt(content)
    ) {
      return;
    }
    if (!content && attachments.length === 0) {
      return;
    }
    byId[row.id].messages.push({
      role: row.role,
      timestamp: normalizeDatabaseTimestamp(row.message_created_at),
      content: content,
      attachments: attachments
    });
  });

  const sessions = Object.keys(byId).map(function (sessionId) {
    const session = byId[sessionId];
    if (!session.messages.some(function (message) {
      return message.role === "user";
    })) {
      return null;
    }
    if (!session.title) {
      const firstUser = session.messages.find(function (message) {
        return message.role === "user";
      });
      session.title = firstUser.content ||
        firstUser.attachments.map(function (attachment) {
          return attachment.name;
        }).join(", ");
    }
    return session;
  }).filter(function (session) {
    return session !== null;
  });
  const latestScheduledSessionByTask = {};
  sessions.forEach(function (session) {
    if (!session.scheduledTaskId) {
      return;
    }
    const latest = latestScheduledSessionByTask[session.scheduledTaskId];
    if (
      !latest ||
      session.scheduledRunAt > latest.scheduledRunAt ||
      (
        session.scheduledRunAt === latest.scheduledRunAt &&
        session.sessionId > latest.sessionId
      )
    ) {
      latestScheduledSessionByTask[session.scheduledTaskId] = session;
    }
  });
  return sessions.filter(function (session) {
    return !session.scheduledTaskId ||
      latestScheduledSessionByTask[session.scheduledTaskId] === session;
  }).sort(compareSessionsByUpdatedAt);
}

function workbuddyAttachments(record) {
  const attachments = [];
  const identifier = typeof record.id === "string" ? record.id : null;
  let content = record.content;
  if (!Array.isArray(content) && record.message) {
    content = record.message.content;
  }
  if (!Array.isArray(content)) {
    return attachments;
  }

  content.forEach(function (item) {
    if (!item || typeof item !== "object") {
      return;
    }
    if (
      (
        item.type !== "input_text" &&
        item.type !== "output_text" &&
        item.type !== "text"
      ) ||
      typeof item.text !== "string"
    ) {
      return;
    }
    const itemText =
      record.role === "user" &&
      item.providerData &&
      typeof item.providerData.content === "string"
        ? item.providerData.content
        : item.text;

    inlineQuotedFileReferencePattern.lastIndex = 0;
    let fileMatch;
    while (
      (fileMatch = inlineQuotedFileReferencePattern.exec(itemText)) !== null
    ) {
      const path = fileMatch[2];
      attachments.push({
        name: baseName(path),
        absPath: path,
        identifier: identifier
      });
    }
    const textWithoutQuotedFiles = itemText.replace(
      inlineQuotedFileReferencePattern,
      ""
    );
    inlineFileReferencePattern.lastIndex = 0;
    while (
      (fileMatch = inlineFileReferencePattern.exec(textWithoutQuotedFiles)) !==
      null
    ) {
      const path = fileMatch[1];
      attachments.push({
        name: baseName(path),
        absPath: path,
        identifier: identifier
      });
    }

    imageLocalPathPattern.lastIndex = 0;
    let imageMatch;
    while ((imageMatch = imageLocalPathPattern.exec(itemText)) !== null) {
      const path = decodeXmlText(imageMatch[1]).trim();
      if (!path) {
        continue;
      }
      const name = baseName(path);
      attachments.push({
        name: name,
        absPath: path,
        identifier: identifier
      });
    }
  });

  const seen = {};
  return attachments.filter(function (attachment) {
    if (seen[attachment.absPath]) {
      return false;
    }
    seen[attachment.absPath] = true;
    return true;
  });
}

function convertWorkbuddyShareHtmlLinks(text) {
  const pattern =
    /@share-html(?:#([^:\s@]+))?:(https?:\/\/[^\s@\u3400-\u9fff\uf900-\ufaff]*\.html(?:[?#][^\s@\u3400-\u9fff\uf900-\ufaff]*)?)/gi;
  return text.replace(pattern, function (_match, encodedName, url) {
    if (!encodedName) {
      encodedName = url.split(/[?#]/, 1)[0].split("/").pop();
    }
    let name = encodedName;
    try {
      name = decodeURIComponent(encodedName);
    } catch (_) {
      // Preserve malformed source labels instead of dropping the link.
    }
    const label = name
      .replace(/\\/g, "\\\\")
      .replace(/\[/g, "\\[")
      .replace(/\]/g, "\\]");
    const destination = url
      .replace(/\\/g, "\\\\")
      .replace(/\(/g, "\\(")
      .replace(/\)/g, "\\)");
    return "[" + label + "](" + destination + ")";
  });
}

function cleanWorkbuddyMessageText(text, attachments) {
  let value = convertWorkbuddyShareHtmlLinks(text)
    .replace(imageLocalPathPattern, "")
    .replace(inlineImageReferencePrefixPattern, "")
    .replace(inlineQuotedFileReferencePattern, function (
      _match,
      _quote,
      path
    ) {
      return baseName(path);
    });
  attachments.forEach(function (attachment) {
    value = replaceAllLiteral(
      value,
      "@" + attachment.absPath,
      attachment.name
    );
  });
  return value.replace(/[ \t]+(?=\r?\n)/g, "").trim();
}

function workbuddyPresentedArtifacts(sessionId) {
  const home = ObjC.unwrap($.NSHomeDirectory());
  const path = home + "/.workbuddy/artifact-index/" + sessionId + ".json";
  if (!fileExists(path)) {
    return {};
  }
  const index = JSON.parse(readUtf8(path));
  const byRequestId = {};
  (Array.isArray(index.artifacts) ? index.artifacts : []).forEach(function (
    artifact
  ) {
    const metadata = artifact && artifact._meta;
    const sourceTool = metadata && metadata.sourceTool;
    const normalizedTool = typeof sourceTool === "string"
      ? sourceTool.toLowerCase().replace(/_/g, "")
      : "";
    if (
      !metadata ||
      metadata.ownerConversationId !== sessionId ||
      normalizedTool !== "presentfiles" ||
      typeof metadata.requestId !== "string" ||
      typeof artifact.uri !== "string"
    ) {
      return;
    }
    const url = $.NSURL.URLWithString($(artifact.uri));
    if (!url || !url.isFileURL) {
      return;
    }
    const artifactPath = ObjC.unwrap(url.path);
    if (!artifactPath || !fileExists(artifactPath)) {
      return;
    }
    if (!byRequestId[metadata.requestId]) {
      byRequestId[metadata.requestId] = [];
    }
    byRequestId[metadata.requestId].push({
      name: typeof artifact.name === "string" && artifact.name
        ? artifact.name
        : baseName(artifactPath),
      absPath: artifactPath,
      identifier: null
    });
  });
  Object.keys(byRequestId).forEach(function (requestId) {
    byRequestId[requestId] = mergeAttachments([], byRequestId[requestId]);
  });
  return byRequestId;
}

function makeSession(sessionId, path, messages, explicitTitle) {
  if (!messages.some(function (message) { return message.role === "user"; })) {
    return null;
  }
  const firstUser = messages.find(function (message) {
    return message.role === "user";
  });
  const textTitle =
    firstUser.content.split(/\r?\n/).join(" ").replace(/\s+/g, " ").trim();
  const attachmentTitle = (firstUser.attachments || []).map(function (
    attachment
  ) {
    return attachment.name;
  }).join(", ");
  const title = explicitTitle || textTitle || attachmentTitle;
  return {
    sessionId: sessionId,
    sourcePath: path,
    title: title,
    startedAt: messages[0].timestamp,
    updatedAt: messages[messages.length - 1].timestamp,
    messages: messages
  };
}

function workbuddyVisibleUserQueries(text) {
  const values = [];
  const tagPattern =
    /<(\/?)([a-z][\w:.-]*)(?:\s[^>]*?)?(\/?)>/gi;
  const stack = [];
  let match;
  while ((match = tagPattern.exec(text)) !== null) {
    const name = match[2].toLowerCase();
    const isClosing = match[1] === "/";
    if (!isClosing) {
      if (match[3] !== "/") {
        stack.push({
          name: name,
          contentStart: match.index + match[0].length,
          isTopLevelQuery: name === "user_query" && stack.length === 0
        });
      }
      continue;
    }

    let openIndex = -1;
    for (let index = stack.length - 1; index >= 0; index -= 1) {
      if (stack[index].name === name) {
        openIndex = index;
        break;
      }
    }
    if (openIndex < 0) {
      continue;
    }
    const openingTag = stack[openIndex];
    if (openingTag.isTopLevelQuery) {
      values.push(text.slice(openingTag.contentStart, match.index));
    }
    stack.splice(openIndex);
  }
  if (values.length > 0) {
    return values;
  }
  return [text.replace(
    /<system-reminder(?:\s[^>]*)?>[\s\S]*?<\/system-reminder>\s*/gi,
    ""
  ).trim()];
}

function extractWorkbuddyUserTexts(record, attachments) {
  const values = [];
  let content = record.content;
  if (!Array.isArray(content) && record.message) {
    content = record.message.content;
  }
  (Array.isArray(content) ? content : []).forEach(function (item) {
    if (
      !item ||
      (item.type !== "input_text" && item.type !== "text") ||
      typeof item.text !== "string"
    ) {
      return;
    }
    const rawText =
      item.providerData &&
      typeof item.providerData.content === "string"
        ? item.providerData.content
        : item.text;
    workbuddyVisibleUserQueries(rawText).forEach(function (visibleText) {
      const query = cleanWorkbuddyMessageText(visibleText, attachments);
      if (query) {
        values.push(query);
      }
    });
  });
  return values;
}

function appendWorkbuddyMessage(
  messages,
  role,
  timestamp,
  content,
  attachments
) {
  if (
    role === "assistant" &&
    messages.length > 0 &&
    messages[messages.length - 1].role === "assistant"
  ) {
    const previous = messages[messages.length - 1];
    previous.content =
      previous.content.replace(/\s+$/, "") + "\n\n" + content.replace(/^\s+/, "");
    Array.prototype.push.apply(previous.attachments, attachments || []);
    return;
  }
  messages.push({
    role: role,
    timestamp: timestamp,
    content: content,
    attachments: attachments || []
  });
}

function parseWorkbuddySession(path) {
  const records = parseJsonl(path);
  const sessionId = sessionIdFrom(records, path);
  const messages = [];
  let explicitTitle = null;
  const presentedArtifacts = workbuddyPresentedArtifacts(sessionId);

  records.forEach(function (record) {
    if (record.type === "ai-title") {
      if (typeof record.aiTitle === "string" && record.aiTitle.trim()) {
        explicitTitle = record.aiTitle.trim();
      }
      return;
    }
    if (record.type !== "message") {
      return;
    }
    if (record.role !== "user" && record.role !== "assistant") {
      return;
    }
    if (isWorkbuddyMetaMessage(record)) {
      return;
    }
    if (
      record.role === "assistant" &&
      record.status !== undefined &&
      record.status !== "completed"
    ) {
      return;
    }
    if (
      record.role === "assistant" &&
      !Object.prototype.hasOwnProperty.call(record, "message")
    ) {
      return;
    }

    const timestamp = normalizeTimestamp(record.timestamp);
    let attachments = workbuddyAttachments(record);
    if (record.role === "assistant" && record.providerData) {
      const requestId =
        record.providerData.conversationRequestId ||
        record.providerData.traceId;
      if (typeof requestId === "string" && presentedArtifacts[requestId]) {
        attachments = mergeAttachments(
          attachments,
          presentedArtifacts[requestId].map(function (attachment) {
            return {
              name: attachment.name,
              absPath: attachment.absPath,
              identifier: record.id
            };
          })
        );
      }
    }
    const texts = record.role === "user"
      ? extractWorkbuddyUserTexts(record, attachments)
      : contentTexts(record, ["output_text", "text"]).map(function (text) {
        return cleanWorkbuddyMessageText(text, attachments);
      });
    texts.forEach(function (rawText, textIndex) {
      const content = rawText.trim();
      if (content) {
        appendWorkbuddyMessage(
          messages,
          record.role,
          timestamp,
          content,
          textIndex === 0 ? attachments : []
        );
      }
    });
  });
  return makeSession(sessionId, path, messages, explicitTitle);
}

function sourceConfiguration(source) {
  const home = ObjC.unwrap($.NSHomeDirectory());
  if (source === "qwenwork") {
    return {
      root: home + "/.qwenworkcn/projects",
      output: home + "/Downloads/qwenwork-sessions.jsonl",
      assetOutput: home + "/Downloads/qwenwork-import.jsonl"
    };
  }
  if (source === "workbuddy") {
    return {
      root: home + "/.workbuddy/projects",
      output: home + "/Downloads/workbuddy-sessions.jsonl",
      assetOutput: home + "/Downloads/workbuddy-import.jsonl"
    };
  }
  fail("Unsupported source: " + source);
}

function jsonlPaths(root) {
  if (!fileManager.fileExistsAtPath(root)) {
    fail("Session directory not found: " + root);
  }
  const relativePaths = ObjC.deepUnwrap(fileManager.subpathsAtPath(root)) || [];
  return relativePaths.filter(function (relativePath) {
    return relativePath.endsWith(".jsonl");
  }).map(function (relativePath) {
    return root + "/" + relativePath;
  }).sort();
}

function workbuddyWorkspaceKey(path) {
  const separatorIndex = Math.max(
    path.lastIndexOf("/"),
    path.lastIndexOf("\\")
  );
  const key = separatorIndex > 0
    ? baseName(path.slice(0, separatorIndex))
    : "";
  if (!key) {
    fail("Cannot determine WorkBuddy workspace key from: " + path);
  }
  return key;
}

function discoverWorkbuddySessions(root) {
  const storedSessions = workbuddySessionMetadata();
  const pathsById = {};
  jsonlPaths(root).forEach(function (path) {
    const filename = baseName(path);
    const sessionId = filename.slice(0, -".jsonl".length);
    if (!storedSessions[sessionId]) {
      return;
    }
    if (pathsById[sessionId]) {
      fail(
        "Duplicate session ID " + sessionId + ": " +
        pathsById[sessionId] + ", " + path
      );
    }
    pathsById[sessionId] = path;
  });

  return Object.keys(storedSessions).map(function (sessionId) {
    const path = pathsById[sessionId];
    if (!path) {
      fail("WorkBuddy session event stream not found: " + sessionId);
    }
    const session = parseWorkbuddySession(path);
    if (session) {
      const metadata = storedSessions[sessionId];
      session.startedAt = metadata.startedAt;
      session.updatedAt = metadata.updatedAt;
      if (metadata.isWorkspace) {
        session.projectId = workbuddyWorkspaceKey(path);
        session.projectName = baseName(metadata.cwd);
        session.projectDescription = "";
      }
      if (metadata.title) {
        session.title = metadata.title;
      }
    }
    return session;
  }).filter(function (session) {
    return session !== null;
  }).sort(compareSessionsByUpdatedAt);
}

function parseArguments(argv) {
  const options = {
    source: null,
    sourceRoot: null,
    command: null,
    json: false,
    all: false,
    sessionIds: [],
    titles: [],
    cursor: null,
    output: null,
    assetOutput: null,
    mergeAssetOutput: false,
    overwrite: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const value = String(argv[index]);
    if (value === "--") {
      continue;
    } else if (value === "list" || value === "export") {
      if (options.command) {
        fail("Only one command may be specified");
      }
      options.command = value;
    } else if (value === "--source") {
      options.source = String(argv[++index] || "");
    } else if (value === "--source-root") {
      options.sourceRoot = String(argv[++index] || "");
    } else if (value === "--json") {
      options.json = true;
    } else if (value === "--all") {
      options.all = true;
    } else if (value === "--session-id") {
      options.sessionIds.push(String(argv[++index] || ""));
    } else if (value === "--title") {
      options.titles.push(String(argv[++index] || ""));
    } else if (value === "--cursor") {
      if (options.cursor !== null) {
        fail("--cursor may be specified only once");
      }
      options.cursor = String(argv[++index] || "");
    } else if (value === "--output") {
      options.output = String(argv[++index] || "");
    } else if (value === "--asset-output") {
      options.assetOutput = String(argv[++index] || "");
    } else if (value === "--merge-asset-output") {
      options.mergeAssetOutput = true;
    } else if (value === "--overwrite") {
      options.overwrite = true;
    } else {
      fail("Unknown argument: " + value);
    }
  }

  if (!options.source || !options.command) {
    fail("Usage: --source <qwenwork|workbuddy> <list|export> [options]");
  }
  if (
    options.command === "export" &&
    [
      options.all,
      options.sessionIds.length > 0,
      options.titles.length > 0,
      options.cursor !== null
    ]
      .filter(Boolean).length !== 1
  ) {
    fail(
      "Export requires exactly one selector: " +
      "--all, --session-id, --title, or --cursor"
    );
  }
  return options;
}

function selectSessions(sessions, options) {
  if (options.all) {
    return sessions;
  }
  if (options.cursor !== null) {
    const cursor = timestampMilliseconds(options.cursor, "Cursor");
    return sessions.filter(function (session) {
      return timestampMilliseconds(
        session.startedAt,
        "Session " + session.sessionId + " start timestamp"
      ) > cursor;
    });
  }
  const selected = [];

  options.sessionIds.forEach(function (sessionId) {
    const match = sessions.find(function (session) {
      return session.sessionId === sessionId;
    });
    if (!match) {
      fail("Session ID not found: " + sessionId);
    }
    selected.push(match);
  });

  options.titles.forEach(function (title) {
    const matches = sessions.filter(function (session) {
      return session.title === title;
    });
    if (matches.length === 0) {
      fail("Session title not found: " + title);
    }
    if (matches.length > 1) {
      fail(
        "Ambiguous session title '" + title + "'; use a session ID: " +
        matches.map(function (session) {
          return session.sessionId;
        }).join(", ")
      );
    }
    selected.push(matches[0]);
  });

  const unique = {};
  selected.forEach(function (session) {
    unique[session.sessionId] = session;
  });
  return Object.keys(unique).map(function (sessionId) {
    return unique[sessionId];
  }).sort(compareSessionsByUpdatedAt);
}

function sessionRecord(session) {
  let lastQueryMessageId = null;
  const messages = session.messages.map(function (message, index) {
    const sequence = String(index + 1);
    const messageId = "msg_" +
      (sequence.length >= 3 ? sequence : ("000" + sequence).slice(-3));
    let messageType;
    if (message.role === "user") {
      messageType = "query";
      lastQueryMessageId = messageId;
    } else if (message.role === "assistant") {
      messageType = "answer";
      if (lastQueryMessageId === null) {
        fail(
          "Assistant message has no preceding user message in session " +
          session.sessionId
        );
      }
    } else {
      fail("Unsupported message role: " + message.role);
    }

    const record = {
      message_id: messageId,
      conversation_id: session.sessionId,
      message_type: messageType
    };
    if (messageType === "answer") {
      record.reply_message_id = lastQueryMessageId;
    }
    const content = [];
    if (message.content !== "") {
      content.push({
        content_id: String(content.length + 1),
        content_type: "text",
        text: {text: message.content}
      });
    }
    (message.attachments || []).forEach(function (attachment) {
      content.push({
        content_id: String(content.length + 1),
        content_type: "attachment",
        attachment: {
          type: 8,
          identifier: attachment.identifier,
          local_item: {
            name: attachment.name,
            abs_path: attachment.absPath,
            file_type: 1
          }
        }
      });
    });
    record.content = content;
    return record;
  });

  const record = {
    conversation_id: session.sessionId,
    title: session.title,
    messages: messages,
    message_ids: messages.map(function (message) {
      return message.message_id;
    })
  };
  if (session.projectId) {
    record.project_id = session.projectId;
  }
  return record;
}

function projectRecords(sessions) {
  const projects = {};
  sessions.forEach(function (session) {
    if (!session.projectId) {
      return;
    }
    if (!projects[session.projectId]) {
      projects[session.projectId] = {
        item_type: "project",
        project_id: session.projectId,
        name: session.projectName || "",
        description: session.projectDescription || "",
        conversation_ids: []
      };
    }
    const project = projects[session.projectId];
    if (
      project.name !== (session.projectName || "") ||
      project.description !== (session.projectDescription || "")
    ) {
      fail("Conflicting project metadata: " + session.projectId);
    }
    project.conversation_ids.push(session.sessionId);
  });
  return Object.keys(projects).map(function (projectId) {
    return projects[projectId];
  });
}

function validateProjectRecord(record) {
  if (
    record.item_type !== "project" ||
    typeof record.project_id !== "string" ||
    record.project_id === "" ||
    typeof record.name !== "string" ||
    typeof record.description !== "string" ||
    !Array.isArray(record.conversation_ids) ||
    record.conversation_ids.length < 1 ||
    record.conversation_ids.some(function (conversationId) {
      return typeof conversationId !== "string" || conversationId === "";
    })
  ) {
    fail("Invalid project record");
  }
}

function validateSessionRecord(record) {
  if (
    typeof record.conversation_id !== "string" ||
    record.conversation_id === "" ||
    typeof record.title !== "string" ||
    !Array.isArray(record.messages) ||
    !Array.isArray(record.message_ids) ||
    record.messages.length !== record.message_ids.length ||
    (
      Object.prototype.hasOwnProperty.call(record, "project_id") &&
      (
        typeof record.project_id !== "string" ||
        record.project_id === ""
      )
    )
  ) {
    fail("Invalid session record");
  }

  let lastQueryMessageId = null;
  record.messages.forEach(function (message, index) {
    const sequence = String(index + 1);
    const expectedId = "msg_" +
      (sequence.length >= 3 ? sequence : ("000" + sequence).slice(-3));
    if (
      message.message_id !== expectedId ||
      record.message_ids[index] !== expectedId ||
      message.conversation_id !== record.conversation_id ||
      !Array.isArray(message.content) ||
      message.content.length < 1
    ) {
      fail("Invalid message record in " + record.conversation_id);
    }

    message.content.forEach(function (content, contentIndex) {
      if (!content || content.content_id !== String(contentIndex + 1)) {
        fail("Invalid message content in " + record.conversation_id);
      }
      if (content.content_type === "text") {
        if (!content.text || typeof content.text.text !== "string") {
          fail("Invalid text content in " + record.conversation_id);
        }
        return;
      }
      const attachment = content.attachment;
      const localItem = attachment && attachment.local_item;
      if (
        content.content_type !== "attachment" ||
        !attachment ||
        attachment.type !== 8 ||
        typeof attachment.identifier !== "string" ||
        attachment.identifier === "" ||
        !localItem ||
        typeof localItem.name !== "string" ||
        localItem.name === "" ||
        typeof localItem.abs_path !== "string" ||
        localItem.abs_path === "" ||
        localItem.file_type !== 1
      ) {
        fail("Invalid attachment content in " + record.conversation_id);
      }
    });

    if (message.message_type === "query") {
      if (Object.prototype.hasOwnProperty.call(message, "reply_message_id")) {
        fail("Query message cannot reply to another message");
      }
      lastQueryMessageId = message.message_id;
    } else if (
      message.message_type !== "answer" ||
      message.reply_message_id !== lastQueryMessageId ||
      lastQueryMessageId === null
    ) {
      fail("Invalid answer linkage in " + record.conversation_id);
    }
  });
}

function parseExportJsonl(text, path) {
  if (!text.endsWith("\n")) {
    fail("JSONL export must end with LF: " + path);
  }
  return text.slice(0, -1).split("\n").map(function (line, index) {
    if (line === "" || line.indexOf("\r") !== -1) {
      fail("Invalid JSONL line at " + path + ":" + (index + 1));
    }
    const value = JSON.parse(line);
    if (value === null || Array.isArray(value) || typeof value !== "object") {
      fail("Non-object JSONL value at " + path + ":" + (index + 1));
    }
    return value;
  });
}

function parseAssetJsonl(text, path) {
  if (text === "") {
    return [];
  }
  if (!text.endsWith("\n")) {
    fail("JSONL package must end with LF: " + path);
  }
  return text.slice(0, -1).split("\n").map(function (line, index) {
    if (line === "" || line.indexOf("\r") !== -1) {
      fail("Invalid JSONL line at " + path + ":" + (index + 1));
    }
    const value = JSON.parse(line);
    if (
      value === null ||
      Array.isArray(value) ||
      typeof value !== "object" ||
      typeof value.item_type !== "string" ||
      value.item_type === ""
    ) {
      fail("Invalid asset record at " + path + ":" + (index + 1));
    }
    return {raw: line, value: value};
  });
}

function prepareProjectPackage(projects, output, overwrite, mergeExisting) {
  if (projects.length === 0) {
    return null;
  }
  projects.forEach(validateProjectRecord);
  const outputExists = fileManager.fileExistsAtPath(output);
  if (outputExists && !mergeExisting && !overwrite) {
    fail(
      "Asset destination already exists; pass --overwrite to replace it: " +
      output
    );
  }
  const existingText = outputExists && mergeExisting ? readUtf8(output) : "";
  const existing = parseAssetJsonl(existingText, output);
  const projectIndexes = [];
  existing.forEach(function (record, index) {
    if (record.value.item_type === "project") {
      projectIndexes.push(index);
    }
  });
  if (projectIndexes.length > 0 && !overwrite) {
    fail(
      "Project collection already exists; pass --overwrite to replace it: " +
      output
    );
  }

  const projectLines = projects.map(function (project) {
    return JSON.stringify(project);
  });
  const lines = [];
  let inserted = false;
  existing.forEach(function (record) {
    if (record.value.item_type === "project") {
      if (!inserted) {
        Array.prototype.push.apply(lines, projectLines);
        inserted = true;
      }
      return;
    }
    lines.push(record.raw);
  });
  if (!inserted) {
    Array.prototype.push.apply(lines, projectLines);
  }

  const candidate = lines.join("\n") + "\n";
  const parsed = parseAssetJsonl(candidate, output);
  const parsedProjects = parsed.filter(function (record) {
    return record.value.item_type === "project";
  }).map(function (record) {
    validateProjectRecord(record.value);
    return record.value;
  });
  const existingOtherLines = existing.filter(function (record) {
    return record.value.item_type !== "project";
  }).map(function (record) {
    return record.raw;
  });
  const parsedOtherLines = parsed.filter(function (record) {
    return record.value.item_type !== "project";
  }).map(function (record) {
    return record.raw;
  });
  if (
    JSON.stringify(parsedProjects) !== JSON.stringify(projects) ||
    JSON.stringify(parsedOtherLines) !== JSON.stringify(existingOtherLines)
  ) {
    fail("In-memory project package validation failed");
  }
  return {output: output, candidate: candidate};
}

function writeProjectPackage(prepared) {
  if (!prepared) {
    return;
  }
  const outputString = $(prepared.output);
  const outputDirectory = ObjC.unwrap(outputString.stringByDeletingLastPathComponent);
  if (!fileManager.fileExistsAtPath(outputDirectory)) {
    fail("Asset output directory does not exist: " + outputDirectory);
  }
  const processId = ObjC.unwrap($.NSProcessInfo.processInfo.processIdentifier);
  const temporaryPath = prepared.output + ".tmp." + processId;
  try {
    writeUtf8(temporaryPath, prepared.candidate);
    const validated = readUtf8(temporaryPath);
    if (
      validated !== prepared.candidate ||
      parseAssetJsonl(validated, temporaryPath).length === 0
    ) {
      fail("Project package validation failed");
    }
    if (fileManager.fileExistsAtPath(prepared.output)) {
      fileManager.removeItemAtPathError(prepared.output, null);
    }
    if (
      !fileManager.moveItemAtPathToPathError(
        temporaryPath,
        prepared.output,
        null
      )
    ) {
      fail("Cannot finalize asset package: " + prepared.output);
    }
  } finally {
    if (fileManager.fileExistsAtPath(temporaryPath)) {
      fileManager.removeItemAtPathError(temporaryPath, null);
    }
  }
}

function writeSessions(sessions, output, overwrite) {
  if (fileManager.fileExistsAtPath(output) && !overwrite) {
    fail("Destination already exists; pass --overwrite to replace it: " + output);
  }

  const records = sessions.map(sessionRecord);
  records.forEach(validateSessionRecord);
  const candidate = records.map(function (record) {
    return JSON.stringify(record);
  }).join("\n") + "\n";
  const parsedCandidate = parseExportJsonl(candidate, output);
  parsedCandidate.forEach(validateSessionRecord);
  if (JSON.stringify(parsedCandidate) !== JSON.stringify(records)) {
    fail("In-memory session JSONL validation failed");
  }

  const outputString = $(output);
  const outputDirectory = ObjC.unwrap(outputString.stringByDeletingLastPathComponent);
  if (!fileManager.fileExistsAtPath(outputDirectory)) {
    fail("Output directory does not exist: " + outputDirectory);
  }

  const processId = ObjC.unwrap($.NSProcessInfo.processInfo.processIdentifier);
  const temporaryPath = output + ".tmp." + processId;
  try {
    writeUtf8(temporaryPath, candidate);
    const validated = readUtf8(temporaryPath);
    const validatedRecords = parseExportJsonl(validated, temporaryPath);
    validatedRecords.forEach(validateSessionRecord);
    if (
      validated !== candidate ||
      JSON.stringify(validatedRecords) !== JSON.stringify(records)
    ) {
      fail("Session JSONL validation failed");
    }
    if (fileManager.fileExistsAtPath(output)) {
      fileManager.removeItemAtPathError(output, null);
    }
    if (!fileManager.moveItemAtPathToPathError(temporaryPath, output, null)) {
      fail("Cannot finalize session file: " + output);
    }
  } finally {
    if (fileManager.fileExistsAtPath(temporaryPath)) {
      fileManager.removeItemAtPathError(temporaryPath, null);
    }
  }
}

function run(argv) {
  const options = parseArguments(argv);
  const configuration = sourceConfiguration(options.source);
  const root = options.sourceRoot || configuration.root;
  let sessions;
  if (options.source === "qwenwork") {
    sessions = qwenworkDatabaseSessions();
  } else {
    sessions = discoverWorkbuddySessions(root);
  }

  if (options.command === "list") {
    const summaries = sessions.map(function (session) {
      return {
        session_id: session.sessionId,
        title: session.title,
        started_at: session.startedAt,
        message_count: session.messages.length
      };
    });
    if (options.json) {
      return JSON.stringify(summaries, null, 2);
    }
    return summaries.map(function (summary) {
      return [
        summary.session_id,
        summary.started_at,
        summary.title
      ].join("\t");
    }).join("\n");
  }

  const selected = selectSessions(sessions, options);
  if (selected.length === 0) {
    if (options.cursor !== null) {
      if (options.json) {
        return JSON.stringify({
          source: options.source,
          output: null,
          asset_output: null,
          session_count: 0,
          next_cursor: timestampMilliseconds(options.cursor, "Cursor")
        });
      }
      return "No sessions found after cursor " + options.cursor;
    }
    if (options.all && options.json) {
      return JSON.stringify({
        source: options.source,
        output: null,
        asset_output: null,
        session_count: 0,
        next_cursor: null
      });
    }
    fail("No sessions selected");
  }
  const output = options.output || configuration.output;
  const projects = projectRecords(selected);
  let assetOutput = null;
  if (projects.length > 0) {
    assetOutput = options.assetOutput || (
      options.output
        ? ObjC.unwrap($(output).stringByDeletingLastPathComponent) +
          "/" + options.source + "-import.jsonl"
        : configuration.assetOutput
    );
    if (assetOutput === output) {
      fail("Session output and asset output must be different files");
    }
  }
  const preparedProjectPackage = prepareProjectPackage(
    projects,
    assetOutput,
    options.overwrite,
    options.mergeAssetOutput
  );
  writeSessions(selected, output, options.overwrite);
  writeProjectPackage(preparedProjectPackage);
  const nextCursor = selected.reduce(function (latest, session) {
    return Math.max(
      latest,
      timestampMilliseconds(
        session.startedAt,
        "Session " + session.sessionId + " start timestamp"
      )
    );
  }, Number.NEGATIVE_INFINITY);
  if (options.json) {
    return JSON.stringify({
      source: options.source,
      output: output,
      asset_output: assetOutput,
      session_count: selected.length,
      next_cursor: nextCursor
    });
  }
  return "Exported " + selected.length + " session(s) to " + output +
    (assetOutput ? "; projects to " + assetOutput : "") +
    "; next cursor " + nextCursor;
}
