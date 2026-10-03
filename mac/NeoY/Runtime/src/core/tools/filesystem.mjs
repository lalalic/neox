export const FILESYSTEM_TOOLS = [
{
    name: "fs_read",
    title: "Read file",
    description: "Read any file accessible to the macOS user. Supports byte ranges and text or base64 output.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string" },
        encoding: { type: "string", enum: ["utf8", "base64"], default: "utf8" },
        offset: { type: "integer", minimum: 0, default: 0 },
        max_bytes: { type: "integer", minimum: 1, maximum: 64000000, default: 1000000 },
      },
      required: ["path"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
{
    name: "fs_write",
    title: "Write file",
    description: "Create, replace, or append to any file accessible to the macOS user. Parent directories can be created automatically. Replacement writes are atomic by default.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string" },
        content: { type: "string" },
        encoding: { type: "string", enum: ["utf8", "base64"], default: "utf8" },
        append: { type: "boolean", default: false },
        atomic: { type: "boolean", default: true },
        create_parents: { type: "boolean", default: true },
        mode: { type: "integer", minimum: 0, maximum: 4095, description: "Optional POSIX mode as a decimal integer, for example 420 for 0644." },
      },
      required: ["path", "content"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
  },
{
    name: "fs_list",
    title: "List directory",
    description: "List a directory, optionally recursively, with type, size, mode, and timestamps. Symlinks are not followed during recursion.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string" },
        recursive: { type: "boolean", default: false },
        include_hidden: { type: "boolean", default: true },
        max_entries: { type: "integer", minimum: 1, maximum: 100000, default: 5000 },
        max_depth: { type: "integer", minimum: 0, maximum: 100, default: 10 },
      },
      required: ["path"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
{
    name: "fs_stat",
    title: "Inspect filesystem path",
    description: "Return lstat metadata for any accessible filesystem path, including symlink target when applicable.",
    inputSchema: { type: "object", properties: { path: { type: "string" } }, required: ["path"], additionalProperties: false },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
{
    name: "fs_manage",
    title: "Manage filesystem path",
    description: "Perform unrestricted filesystem operations: mkdir, remove, move, copy, chmod, or symlink. Remove is recursive when requested. These operations use the host user's permissions.",
    inputSchema: {
      type: "object",
      properties: {
        operation: { type: "string", enum: ["mkdir", "remove", "move", "copy", "chmod", "symlink"] },
        path: { type: "string", description: "Primary path or symlink path." },
        destination: { type: "string", description: "Destination for move/copy, or target for symlink." },
        recursive: { type: "boolean", default: false },
        force: { type: "boolean", default: false },
        mode: { type: "integer", minimum: 0, maximum: 4095 },
      },
      required: ["operation", "path"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
  }
];

export async function handleFilesystem(name, args, context) {
  const { HOME, DEFAULT_OUTPUT_BYTES, MAX_OUTPUT_BYTES, resolvePath, optionalString, optionalBoolean, optionalInteger, requireString, crypto, fsp, path, process, audit } = context;
  switch (name) {
        case "fs_read": {
          const filePath = resolvePath(requireString(args, "path"));
          const encoding = optionalString(args, "encoding", "utf8");
          const offset = optionalInteger(args, "offset", 0, 0, Number.MAX_SAFE_INTEGER);
          const maxBytes = optionalInteger(args, "max_bytes", DEFAULT_OUTPUT_BYTES, 1, MAX_OUTPUT_BYTES);
          const stat = await fsp.stat(filePath);
          if (!stat.isFile()) throw new Error(`Not a regular file: ${filePath}`);
          const bytesToRead = Math.max(0, Math.min(maxBytes, stat.size - offset));
          const handle = await fsp.open(filePath, "r");
          try {
            const buffer = Buffer.alloc(bytesToRead);
            const { bytesRead } = await handle.read(buffer, 0, bytesToRead, offset);
            const data = buffer.subarray(0, bytesRead);
            const result = {
              path: filePath,
              size: stat.size,
              offset,
              bytesRead,
              nextOffset: offset + bytesRead < stat.size ? offset + bytesRead : null,
              truncated: offset + bytesRead < stat.size,
              encoding,
              content: encoding === "base64" ? data.toString("base64") : data.toString("utf8"),
            };
            await audit(name, args, { path: filePath, bytesRead, truncated: result.truncated });
            return result;
          } finally {
            await handle.close();
          }
        }
    
        case "fs_write": {
          const filePath = resolvePath(requireString(args, "path"));
          const content = requireString(args, "content", { allowEmpty: true });
          const encoding = optionalString(args, "encoding", "utf8");
          const append = optionalBoolean(args, "append", false);
          const atomic = optionalBoolean(args, "atomic", true);
          const createParents = optionalBoolean(args, "create_parents", true);
          const mode = args?.mode === undefined ? undefined : optionalInteger(args, "mode", 0o644, 0, 0o7777);
          const data = encoding === "base64" ? Buffer.from(content, "base64") : Buffer.from(content, "utf8");
          if (createParents) await fsp.mkdir(path.dirname(filePath), { recursive: true });
          let effectiveMode = mode;
          if (!append && atomic && effectiveMode === undefined) {
            try {
              effectiveMode = (await fsp.stat(filePath)).mode & 0o7777;
            } catch (error) {
              if (error?.code !== "ENOENT") throw error;
            }
          }
          if (append) {
            await fsp.appendFile(filePath, data, mode === undefined ? undefined : { mode });
          } else if (atomic) {
            const tempPath = path.join(path.dirname(filePath), `.${path.basename(filePath)}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`);
            try {
              await fsp.writeFile(tempPath, data, effectiveMode === undefined ? undefined : { mode: effectiveMode });
              await fsp.rename(tempPath, filePath);
            } catch (error) {
              await fsp.rm(tempPath, { force: true }).catch(() => {});
              throw error;
            }
          } else {
            await fsp.writeFile(filePath, data, mode === undefined ? undefined : { mode });
          }
          if (mode !== undefined) await fsp.chmod(filePath, mode);
          const stat = await fsp.stat(filePath);
          const result = { path: filePath, bytesWritten: data.length, size: stat.size, append, atomic: append ? false : atomic, mode: stat.mode & 0o7777 };
          await audit(name, args, result);
          return result;
        }
    
        case "fs_list": {
          const root = resolvePath(requireString(args, "path"));
          const recursive = optionalBoolean(args, "recursive", false);
          const includeHidden = optionalBoolean(args, "include_hidden", true);
          const maxEntries = optionalInteger(args, "max_entries", 5000, 1, 100000);
          const maxDepth = optionalInteger(args, "max_depth", 10, 0, 100);
          const entries = [];
          let truncated = false;
          async function walk(directory, depth) {
            if (entries.length >= maxEntries) { truncated = true; return; }
            const dirents = await fsp.readdir(directory, { withFileTypes: true });
            dirents.sort((a, b) => a.name.localeCompare(b.name));
            for (const dirent of dirents) {
              if (!includeHidden && dirent.name.startsWith(".")) continue;
              if (entries.length >= maxEntries) { truncated = true; return; }
              const fullPath = path.join(directory, dirent.name);
              const stat = await fsp.lstat(fullPath);
              const entry = {
                name: dirent.name,
                path: fullPath,
                relativePath: path.relative(root, fullPath) || ".",
                type: stat.isDirectory() ? "directory" : stat.isFile() ? "file" : stat.isSymbolicLink() ? "symlink" : "other",
                size: stat.size,
                mode: stat.mode & 0o7777,
                modifiedAt: stat.mtime.toISOString(),
              };
              if (stat.isSymbolicLink()) entry.symlinkTarget = await fsp.readlink(fullPath).catch(() => null);
              entries.push(entry);
              if (recursive && stat.isDirectory() && depth < maxDepth) await walk(fullPath, depth + 1);
            }
          }
          await walk(root, 0);
          const result = { root, entries, count: entries.length, truncated };
          await audit(name, args, { root, count: entries.length, truncated });
          return result;
        }
    
        case "fs_stat": {
          const targetPath = resolvePath(requireString(args, "path"));
          const stat = await fsp.lstat(targetPath);
          const result = {
            path: targetPath,
            type: stat.isDirectory() ? "directory" : stat.isFile() ? "file" : stat.isSymbolicLink() ? "symlink" : stat.isSocket() ? "socket" : "other",
            size: stat.size,
            mode: stat.mode & 0o7777,
            uid: stat.uid,
            gid: stat.gid,
            inode: stat.ino,
            device: stat.dev,
            links: stat.nlink,
            createdAt: stat.birthtime.toISOString(),
            modifiedAt: stat.mtime.toISOString(),
            changedAt: stat.ctime.toISOString(),
            accessedAt: stat.atime.toISOString(),
            symlinkTarget: stat.isSymbolicLink() ? await fsp.readlink(targetPath) : null,
          };
          await audit(name, args, { path: targetPath, type: result.type });
          return result;
        }
    
        case "fs_manage": {
          const operation = requireString(args, "operation");
          const targetPath = resolvePath(requireString(args, "path"));
          const destinationInput = args?.destination === undefined ? undefined : requireString(args, "destination");
          const destination = destinationInput === undefined
            ? undefined
            : operation === "symlink" && !path.isAbsolute(destinationInput) && !destinationInput.startsWith("~/")
              ? destinationInput
              : resolvePath(destinationInput);
          const recursive = optionalBoolean(args, "recursive", false);
          const force = optionalBoolean(args, "force", false);
          const mode = args?.mode === undefined ? undefined : optionalInteger(args, "mode", 0o755, 0, 0o7777);
          switch (operation) {
            case "mkdir":
              await fsp.mkdir(targetPath, { recursive, mode });
              break;
            case "remove":
              await fsp.rm(targetPath, { recursive, force });
              break;
            case "move":
              if (!destination) throw new Error("'destination' is required for move");
              if (force) await fsp.rm(destination, { recursive: true, force: true });
              await fsp.mkdir(path.dirname(destination), { recursive: true });
              try {
                await fsp.rename(targetPath, destination);
              } catch (error) {
                if (error?.code !== "EXDEV") throw error;
                const stat = await fsp.lstat(targetPath);
                await fsp.cp(targetPath, destination, {
                  recursive: stat.isDirectory(),
                  force,
                  errorOnExist: !force,
                  preserveTimestamps: true,
                  verbatimSymlinks: true,
                });
                await fsp.rm(targetPath, { recursive: stat.isDirectory(), force: true });
              }
              break;
            case "copy":
              if (!destination) throw new Error("'destination' is required for copy");
              if (force) await fsp.rm(destination, { recursive: true, force: true });
              await fsp.mkdir(path.dirname(destination), { recursive: true });
              await fsp.cp(targetPath, destination, { recursive, force, errorOnExist: !force, preserveTimestamps: true, verbatimSymlinks: true });
              break;
            case "chmod":
              if (mode === undefined) throw new Error("'mode' is required for chmod");
              await fsp.chmod(targetPath, mode);
              break;
            case "symlink":
              if (!destination) throw new Error("'destination' is required as the symlink target");
              if (force) await fsp.rm(targetPath, { recursive: true, force: true });
              await fsp.mkdir(path.dirname(targetPath), { recursive: true });
              await fsp.symlink(destination, targetPath);
              break;
            default:
              throw new Error(`Unsupported operation: ${operation}`);
          }
          const result = { operation, path: targetPath, destination: destination ?? null, recursive, force, mode: mode ?? null };
          await audit(name, args, result);
          return result;
        }
    default: throw new Error("Unknown filesystem tool: " + name);
  }
}
