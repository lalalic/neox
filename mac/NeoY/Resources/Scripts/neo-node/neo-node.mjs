#!/usr/bin/env node
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";

const HOME = os.homedir();
const CONFIG_FILE = process.env.NEO_NODE_CONFIG || path.join(HOME, ".config/neo-node/node.env");

function parseEnvFile(file) {
  const out = {};
  if (!fs.existsSync(file)) return out;
  for (const raw of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const i = line.indexOf("=");
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 1);
  }
  return out;
}
const cfg = {...process.env, ...parseEnvFile(CONFIG_FILE)};
const NODE_NAME = cfg.NODE_NAME || "node";
const NODE_MODE = cfg.NODE_MODE || "session";
const HUB_SSH_TARGET = cfg.HUB_SSH_TARGET || "";
const HUB_SSH_PORT = Number(cfg.HUB_SSH_PORT || 22);
const HUB_MCP_PORT = Number(cfg.HUB_MCP_PORT || 0);
const LOCAL_MCP_PORT = Number(cfg.LOCAL_MCP_PORT || 8789);
const NODE_ROOT = cfg.NODE_ROOT || path.join(HOME, ".local/share/neo-node");
const NODE_SSH_KEY = cfg.NODE_SSH_KEY || "";
const NODE_BIN = cfg.NODE_BIN || process.execPath;
const SSH_BIN = cfg.SSH_BIN || "/usr/bin/ssh";
const LOG_DIR = path.join(NODE_ROOT, "logs");
const RUN_DIR = path.join(NODE_ROOT, "run");
const SCRIPT = path.join(NODE_ROOT, "neo-node.mjs");
const CLI = path.join(HOME, ".local/bin/neo-node");
const LABEL = `com.neo.node.${NODE_NAME}`;
const PLIST = path.join(HOME, "Library/LaunchAgents", `${LABEL}.plist`);
const PIDS = {
  supervisor: path.join(RUN_DIR, "supervisor.pid"),
  server: path.join(RUN_DIR, "server.pid"),
  tunnel: path.join(RUN_DIR, "tunnel.pid"),
};
const MAX_OUTPUT = 4 * 1024 * 1024;
const sessions = new Map();

fs.mkdirSync(LOG_DIR, {recursive:true});
fs.mkdirSync(RUN_DIR, {recursive:true});

function readPid(file) {
  try { const n=Number(fs.readFileSync(file,"utf8").trim()); return Number.isInteger(n)&&n>0?n:null; } catch { return null; }
}
function alive(pid) {
  if (!pid) return false;
  try { process.kill(pid,0); return true; } catch { return false; }
}
function writePid(file,pid){ fs.writeFileSync(file,String(pid)); }
function unlink(file){ try{fs.unlinkSync(file)}catch{} }
function killPid(file) {
  const pid=readPid(file);
  if (alive(pid)) { try{process.kill(pid,"SIGTERM")}catch{} }
  unlink(file);
}
function sleep(ms){ return new Promise(r=>setTimeout(r,ms)); }
function appendLog(name, data) { if (data) fs.appendFileSync(path.join(LOG_DIR,name), data); }

function health() {
  return new Promise(resolve=>{
    const req=http.get({host:"127.0.0.1",port:LOCAL_MCP_PORT,path:"/healthz",timeout:800},r=>{r.resume();resolve(r.statusCode===200)});
    req.on("error",()=>resolve(false)); req.on("timeout",()=>{req.destroy();resolve(false)});
  });
}
function spawnLogged(cmd,args,log,opts={}) {
  const fd=fs.openSync(path.join(LOG_DIR,log),"a");
  const child=spawn(cmd,args,{stdio:["ignore",fd,fd],...opts});
  child.on("exit",()=>{try{fs.closeSync(fd)}catch{}});
  return child;
}
function tunnelArgs() {
  const args=["-N","-o","BatchMode=yes","-o","ExitOnForwardFailure=yes","-o","ServerAliveInterval=20","-o","ServerAliveCountMax=3","-o","StrictHostKeyChecking=accept-new","-p",String(HUB_SSH_PORT)];
  if (NODE_SSH_KEY && fs.existsSync(NODE_SSH_KEY)) args.push("-i",NODE_SSH_KEY);
  args.push("-R",`127.0.0.1:${HUB_MCP_PORT}:127.0.0.1:${LOCAL_MCP_PORT}`,HUB_SSH_TARGET);
  return args;
}
function startServer() {
  const pid=readPid(PIDS.server); if (alive(pid)) return pid;
  unlink(PIDS.server);
  const child=spawnLogged(NODE_BIN,[SCRIPT,"serve"],"server.log",{env:{...process.env,NEO_NODE_CONFIG:CONFIG_FILE}});
  writePid(PIDS.server,child.pid); return child.pid;
}
function startTunnel() {
  const pid=readPid(PIDS.tunnel); if (alive(pid)) return pid;
  unlink(PIDS.tunnel);
  const child=spawnLogged(SSH_BIN,tunnelArgs(),"tunnel.log");
  writePid(PIDS.tunnel,child.pid); return child.pid;
}
function stopAll() {
  killPid(PIDS.tunnel); killPid(PIDS.server);
  const sup=readPid(PIDS.supervisor);
  if (alive(sup) && sup !== process.pid) { try{process.kill(sup,"SIGTERM")}catch{} }
  if (sup !== process.pid) unlink(PIDS.supervisor);
}
async function runSupervisor() {
  const existing=readPid(PIDS.supervisor);
  if (alive(existing) && existing!==process.pid) return;
  writePid(PIDS.supervisor,process.pid);
  const cleanup=()=>{ killPid(PIDS.tunnel); killPid(PIDS.server); unlink(PIDS.supervisor); };
  process.on("SIGTERM",()=>{cleanup();process.exit(0)}); process.on("SIGINT",()=>{cleanup();process.exit(0)});
  let delay=1000;
  while(true) {
    if (!alive(readPid(PIDS.server)) || !(await health())) {
      killPid(PIDS.server); startServer();
      for(let i=0;i<20 && !(await health());i++) await sleep(250);
    }
    if (!alive(readPid(PIDS.tunnel))) {
      unlink(PIDS.tunnel); startTunnel();
      await sleep(500);
      if (!alive(readPid(PIDS.tunnel))) { await sleep(delay); delay=Math.min(delay*2,30000); continue; }
    }
    await sleep(5000);
    if (alive(readPid(PIDS.tunnel))) delay=1000;
  }
}
async function startSupervisor() {
  if (alive(readPid(PIDS.supervisor))) return true;
  unlink(PIDS.supervisor);
  const child=spawnLogged(NODE_BIN,[SCRIPT,"run"],"supervisor.log",{detached:true,env:{...process.env,NEO_NODE_CONFIG:CONFIG_FILE}});
  child.unref();
  for(let i=0;i<40;i++) {
    if (await health() && alive(readPid(PIDS.tunnel))) return true;
    await sleep(250);
  }
  return await health() && alive(readPid(PIDS.tunnel));
}
function xml(s){return String(s).replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;");}
function install() {
  fs.mkdirSync(path.dirname(CLI),{recursive:true});
  try{unlink(CLI)}catch{}
  try{fs.symlinkSync(SCRIPT,CLI)}catch{ fs.copyFileSync(SCRIPT,CLI); fs.chmodSync(CLI,0o755); }
  if (NODE_MODE !== "persistent") return;
  fs.mkdirSync(path.dirname(PLIST),{recursive:true});
  const plist=`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${xml(LABEL)}</string>
<key>ProgramArguments</key><array><string>${xml(NODE_BIN)}</string><string>${xml(SCRIPT)}</string><string>run</string></array>
<key>EnvironmentVariables</key><dict><key>NEO_NODE_CONFIG</key><string>${xml(CONFIG_FILE)}</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>5</integer>
<key>StandardOutPath</key><string>${xml(path.join(LOG_DIR,"launchd.out.log"))}</string>
<key>StandardErrorPath</key><string>${xml(path.join(LOG_DIR,"launchd.err.log"))}</string>
</dict></plist>
`;
  fs.writeFileSync(PLIST,plist);
  spawnSync("/bin/launchctl",["bootout",`gui/${process.getuid()}/${LABEL}`],{stdio:"ignore"});
  let r=spawnSync("/bin/launchctl",["bootstrap",`gui/${process.getuid()}`,PLIST],{stdio:"ignore"});
  if (r.status!==0) spawnSync("/bin/launchctl",["load","-w",PLIST],{stdio:"ignore"});
}
function uninstallPersistence() {
  spawnSync("/bin/launchctl",["bootout",`gui/${process.getuid()}/${LABEL}`],{stdio:"ignore"});
  spawnSync("/bin/launchctl",["unload",PLIST],{stdio:"ignore"});
  unlink(PLIST);
}
async function status() {
  console.log(`node: ${NODE_NAME}`);
  console.log(`mode: ${NODE_MODE}`);
  console.log(`root: ${NODE_ROOT}`);
  console.log(`local MCP: ${await health()?"healthy":"unavailable"}`);
  for (const [k,f] of Object.entries(PIDS)) { const p=readPid(f); console.log(`${k} pid: ${p??"missing"}${p?(alive(p)?" (alive)":" (stale)"):""}`); }
  console.log(`launchd plist: ${fs.existsSync(PLIST)?"present":"absent"}`);
}
async function doctor() {
  console.log("neo-node doctor");
  console.log(`node=${NODE_NAME} mode=${NODE_MODE}`);
  for(const f of [CONFIG_FILE,SCRIPT]) console.log(`${fs.existsSync(f)?"ok":"missing"} file ${f}`);
  console.log(`${fs.existsSync(NODE_BIN)?"ok":"missing"} node ${NODE_BIN}`);
  console.log(`${fs.existsSync(SSH_BIN)?"ok":"missing"} ssh ${SSH_BIN}`);
  console.log(`${await health()?"ok":"info"} local MCP health`);
}

function resolvePath(v="~") {
  if(v==="~") return HOME;
  if(v.startsWith("~/")) return path.resolve(HOME,v.slice(2));
  return path.resolve(v);
}
async function shellExec(a) {
  const timeout=Math.min(900000,Math.max(1000,Number(a.timeout_ms||120000)));
  return await new Promise(resolve=>{
    const child=spawn(process.env.SHELL||"/bin/zsh",["-lc",a.command],{cwd:resolvePath(a.cwd||"~"),env:process.env});
    let stdout="",stderr="",done=false;
    const timer=setTimeout(()=>{if(!done){child.kill("SIGTERM")}},timeout);
    child.stdout.on("data",d=>stdout=(stdout+d).slice(-MAX_OUTPUT)); child.stderr.on("data",d=>stderr=(stderr+d).slice(-MAX_OUTPUT));
    child.on("close",(code,signal)=>{done=true;clearTimeout(timer);resolve({exitCode:code,signal,timedOut:false,stdout,stderr})});
  });
}
function fsRead(a){const p=resolvePath(a.path);const b=fs.readFileSync(p);const max=Math.min(MAX_OUTPUT,Math.max(1,Number(a.max_bytes||MAX_OUTPUT)));return{path:p,size:b.length,truncated:b.length>max,content:b.subarray(0,max).toString("utf8")}}
function fsWrite(a){const p=resolvePath(a.path);fs.mkdirSync(path.dirname(p),{recursive:true});const content=String(a.content);if(a.append)fs.appendFileSync(p,content);else{const t=`${p}.tmp-${process.pid}-${crypto.randomUUID()}`;fs.writeFileSync(t,content);fs.renameSync(t,p)}return{path:p,bytesWritten:Buffer.byteLength(content),append:!!a.append}}
function fsList(a){const p=resolvePath(a.path||"~");const limit=Math.min(2000,Math.max(1,Number(a.limit||500)));const all=fs.readdirSync(p,{withFileTypes:true});return{path:p,entries:all.slice(0,limit).map(x=>({name:x.name,type:x.isDirectory()?"directory":x.isFile()?"file":x.isSymbolicLink()?"symlink":"other"})),truncated:all.length>limit}}
function processList(a){const r=spawnSync("/bin/ps",["-axo","pid=,ppid=,user=,stat=,%cpu=,%mem=,etime=,command="],{encoding:"utf8"});const q=String(a.query||"").toLowerCase();const limit=Math.min(1000,Math.max(1,Number(a.limit||200)));const rows=(r.stdout||"").split("\n").filter(x=>x&&(!q||x.toLowerCase().includes(q))).slice(0,limit).map(x=>x.trim());return{processes:rows,truncated:rows.length>=limit}}
function shellStart(a){const cwd=resolvePath(a.cwd||"~");const child=spawn(process.env.SHELL||"/bin/zsh",["-lc",a.command],{cwd,env:process.env,stdio:["ignore","pipe","pipe"]});const id=crypto.randomUUID();let stdout="",stderr="";child.stdout.on("data",d=>stdout=(stdout+d).slice(-MAX_OUTPUT));child.stderr.on("data",d=>stderr=(stderr+d).slice(-MAX_OUTPUT));sessions.set(id,{child,cwd,command:a.command,get stdout(){return stdout},get stderr(){return stderr}});return{session_id:id,pid:child.pid,command:a.command,cwd}}
async function shellPoll(a){const s=sessions.get(a.session_id);if(!s)throw new Error(`unknown shell session: ${a.session_id}`);const wait=Math.min(30000,Math.max(0,Number(a.wait_ms||0)));if(s.child.exitCode===null&&wait)await Promise.race([new Promise(r=>s.child.once("close",r)),sleep(wait)]);if(s.child.exitCode===null)return{session_id:a.session_id,running:true,pid:s.child.pid,stdout:"",stderr:""};sessions.delete(a.session_id);return{session_id:a.session_id,running:false,pid:s.child.pid,exitCode:s.child.exitCode,stdout:s.stdout,stderr:s.stderr}}

const tools=[
["shell_exec","Run a shell command.",{type:"object",properties:{command:{type:"string"},cwd:{type:"string"},timeout_ms:{type:"integer"}},required:["command"]}],
["fs_read","Read a UTF-8 file.",{type:"object",properties:{path:{type:"string"},max_bytes:{type:"integer"}},required:["path"]}],
["fs_write","Write a UTF-8 file.",{type:"object",properties:{path:{type:"string"},content:{type:"string"},append:{type:"boolean"}},required:["path","content"]}],
["fs_list","List a directory.",{type:"object",properties:{path:{type:"string"},limit:{type:"integer"}}}],
["process_list","List processes.",{type:"object",properties:{query:{type:"string"},limit:{type:"integer"}}}],
["shell_start","Start a long-running shell command.",{type:"object",properties:{command:{type:"string"},cwd:{type:"string"}},required:["command"]}],
["shell_poll","Poll a shell session.",{type:"object",properties:{session_id:{type:"string"},wait_ms:{type:"integer"}},required:["session_id"]}],
].map(([name,description,inputSchema])=>({name,description:`${description} Node: ${NODE_NAME}.`,inputSchema}));
const handlers={shell_exec:shellExec,fs_read:fsRead,fs_write:fsWrite,fs_list:fsList,process_list:processList,shell_start:shellStart,shell_poll:shellPoll};

function serve() {
  const server=http.createServer(async(req,res)=>{
    if(req.method==="GET"&&req.url==="/healthz"){const b=`ok ${NODE_NAME}\n`;res.writeHead(200,{"Content-Type":"text/plain","Content-Length":Buffer.byteLength(b)});res.end(b);return}
    if(req.method!=="POST"||req.url!=="/mcp"){res.writeHead(404);res.end();return}
    let body="";for await(const d of req)body+=d;
    try{
      const m=JSON.parse(body),id=m.id;let result;
      if(m.method==="initialize")result={protocolVersion:"2025-06-18",capabilities:{tools:{}},serverInfo:{name:`${NODE_NAME}-neo-node`,version:"1.0.0"}};
      else if(m.method==="notifications/initialized"){res.writeHead(202);res.end("{}");return}
      else if(m.method==="tools/list")result={tools};
      else if(m.method==="tools/call"){const p=m.params||{},fn=handlers[p.name];if(!fn)throw new Error(`unknown tool: ${p.name}`);const value=await fn(p.arguments||{});result={content:[{type:"text",text:JSON.stringify(value,null,2)}],isError:false}}
      else {res.writeHead(200,{"Content-Type":"application/json"});res.end(JSON.stringify({jsonrpc:"2.0",id,error:{code:-32601,message:"Method not found"}}));return}
      const out=JSON.stringify({jsonrpc:"2.0",id,result});res.writeHead(200,{"Content-Type":"application/json","Content-Length":Buffer.byteLength(out)});res.end(out);
    }catch(e){const out=JSON.stringify({jsonrpc:"2.0",id:null,error:{code:-32000,message:String(e.message||e)}});res.writeHead(500,{"Content-Type":"application/json","Content-Length":Buffer.byteLength(out)});res.end(out)}
  });
  server.listen(LOCAL_MCP_PORT,"127.0.0.1",()=>console.log(`[${NODE_NAME}] MCP http://127.0.0.1:${LOCAL_MCP_PORT}/mcp`));
}
async function main(){
  const cmd=process.argv[2]||"status";
  if(cmd==="serve")return serve();
  if(cmd==="run")return await runSupervisor();
  if(cmd==="install")return install();
  if(cmd==="uninstall-persistence")return uninstallPersistence();
  if(cmd==="start"){if(!(await startSupervisor()))process.exitCode=1;return}
  if(cmd==="stop")return stopAll();
  if(cmd==="restart"){stopAll();await sleep(500);if(!(await startSupervisor()))process.exitCode=1;return}
  if(cmd==="status")return await status();
  if(cmd==="doctor")return await doctor();
  console.error("usage: neo-node [install|run|start|stop|restart|status|doctor|uninstall-persistence|serve]");process.exitCode=64;
}
main().catch(e=>{console.error(e);process.exitCode=1});
