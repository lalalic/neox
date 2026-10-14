#!/usr/bin/env node
// NeoY read-only filesystem mounts. Changes are picked up by the HTTP server per request.
import {readFileSync,writeFileSync,mkdirSync,realpathSync,statSync,renameSync} from "node:fs";
import {join,resolve,relative,sep,dirname} from "node:path";
import {homedir} from "node:os";
const support=join(homedir(),"Library","Application Support","NeoY");
const config=join(support,"file-mounts.json");
const args=process.argv.slice(2);
let mounts={};
try{mounts=JSON.parse(readFileSync(config,"utf8"));}catch{}
function save(){
  mkdirSync(dirname(config),{recursive:true});
  const temp=config+".new-"+process.pid;
  writeFileSync(temp,JSON.stringify(mounts,null,2)+"\n",{mode:0o600});
  renameSync(temp,config);
}
function usage(){console.error("usage: neoy-files mount <name> <absolute-directory> | unmount <name> | list | url <absolute-file>");process.exitCode=2;}
function validName(name){if(!/^[a-z0-9_-]{1,64}$/i.test(name)||name==="_neoy")throw new Error("Invalid or reserved mount name");}
try{
  if(args[0]==="mount"&&args.length===3){
    validName(args[1]);
    if(!args[2].startsWith("/"))throw new Error("Mount path must be absolute");
    const path=realpathSync(args[2]);
    if(!statSync(path).isDirectory())throw new Error("Mount target must be directory");
    mounts[args[1]]=path;save();
    console.log("Mounted "+args[1]+" -> "+path);
  } else if(args[0]==="unmount"&&args.length===2){
    validName(args[1]);delete mounts[args[1]];save();console.log("Unmounted "+args[1]);
  } else if(args[0]==="list"&&args.length===1){
    console.log(JSON.stringify(mounts,null,2));
  } else if(args[0]==="url"&&args.length===2){
    const deployment=JSON.parse(readFileSync(join(support,"deployment.json"),"utf8"));
    const hostname=deployment.publicHostname;
    if(deployment.tunnelMode!=="named"||!hostname)throw new Error("NeoY needs a configured public HTTPS hostname");
    const file=realpathSync(args[1]);
    const candidate=Object.entries(mounts).find(([name,base])=>{
      validName(name);
      const rel=relative(base,file);
      return rel&&!rel.startsWith(".."+sep)&&rel!==".."&&!rel.startsWith(sep)&&!rel.split(sep).some(x=>x.startsWith("."));
    });
    if(!candidate)throw new Error("File is not within a mounted root");
    const rel=relative(candidate[1],file).split(sep).map(encodeURIComponent).join("/");
    console.log("https://"+hostname+"/files/"+encodeURIComponent(candidate[0])+"/"+rel);
  } else usage();
}catch(error){console.error(error.message);process.exitCode=1;}
