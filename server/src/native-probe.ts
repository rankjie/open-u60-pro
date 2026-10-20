import { randomUUID } from "node:crypto";
import { writeFileSync, renameSync } from "node:fs";
import { privateFile } from "./apns";
import { object, secret } from "./protocol";

async function main() {
  process.umask(0o077);
  const [action,address,invitation,routerFile,phoneFile]=Bun.argv.slice(2);
  if(action==="cleanup") {
    const saved=object(JSON.parse(privateFile(address)));
    if(typeof saved.serverURL!=="string" || typeof saved.token!=="string")throw new Error("Invalid fixture state");
    const response=await fetch(saved.serverURL+"/v1/router",{method:"DELETE",signal:AbortSignal.timeout(10000),headers:{authorization:`Bearer ${saved.token}`}});
    if(!response.ok)throw new Error("Fixture cleanup failed");
    console.info("Synthetic enrollment and registered VoIP token revoked.");return;
  }
  if (action!=="prepare" || !phoneFile) throw new Error("Usage: native-probe.ts prepare https://server invitation-file new-router-file new-phone-file");
  const url=new URL(address);
  if(url.protocol!=="https:" || url.username || url.password || url.search || url.hash) throw new Error("Invalid server address");
  const routerToken=secret(),phoneToken=secret(),phoneRequest=randomUUID();
  const request=async(path:string,token:string|undefined,body:unknown)=>{
    const response=await fetch(address+"/"+path,{method:"POST",signal:AbortSignal.timeout(10000),headers:{"content-type":"application/json",...(token?{authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body)});
    if(!response.ok)throw new Error("Synthetic enrollment failed");
    return object(await response.json());
  };
  const routerRequest=randomUUID();
  writeFileSync(routerFile,JSON.stringify({serverURL:address,token:routerToken,requestId:routerRequest}),{mode:0o600,flag:"wx"});
  writeFileSync(phoneFile,JSON.stringify({serverURL:address,phoneToken,requestId:phoneRequest}),{mode:0o600,flag:"wx"});
  const router=await request("v1/enroll",undefined,{invitation:privateFile(invitation).trim(),deviceToken:routerToken,requestId:routerRequest});
  const pairing=await request("v1/pairings",routerToken,{});
  const phone=await request("v1/pair",undefined,{code:pairing.code,phoneToken,requestId:phoneRequest});
  writeFileSync(routerFile+".ready",JSON.stringify({serverURL:address,token:routerToken,routerId:router.routerId}),{mode:0o600,flag:"wx"});
  renameSync(routerFile+".ready",routerFile);
  writeFileSync(phoneFile+".ready",JSON.stringify({serverURL:address,phoneToken,requestId:phoneRequest,endpointId:phone.endpointId,routerId:phone.routerId}),{mode:0o600,flag:"wx"});
  renameSync(phoneFile+".ready",phoneFile);
  console.info("Isolated synthetic router and phone provisioned; private USB-transfer inputs written.");
}
main().catch(()=>{console.error("Native probe provisioning failed");process.exitCode=1});
