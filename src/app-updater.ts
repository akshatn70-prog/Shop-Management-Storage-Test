import { Capacitor } from "@capacitor/core";
import { Browser } from "@capacitor/browser";
import { App } from "@capacitor/app";

const UPDATE_REPO="geminiusage143-lab/Shop-Management-Storage-Test";

/*
 * Version used only when the app is running as the website.
 * Native Android builds use App.getInfo().version, so the installed APK
 * always checks using its real embedded version.
 */
const WEB_APP_VERSION="1.0.2";

type UpdateMessage=(text:string,type:"info"|"success"|"danger")=>void;

function compareAppVersions(a:string,b:string){
  const pa=a.replace(/^v/i,"").split(".").map(x=>Number.parseInt(x,10)||0);
  const pb=b.replace(/^v/i,"").split(".").map(x=>Number.parseInt(x,10)||0);

  for(let i=0;i<3;i++){
    const av=pa[i]||0;
    const bv=pb[i]||0;

    if(av>bv)return 1;
    if(av<bv)return -1;
  }

  return 0;
}

async function getCurrentAppVersion(){
  if(Capacitor.isNativePlatform()){
    const info=await App.getInfo();
    return String(info.version||WEB_APP_VERSION).replace(/^v/i,"");
  }

  return WEB_APP_VERSION;
}

export async function checkForAppUpdate(message:UpdateMessage){
  try{
    const currentVersion=await getCurrentAppVersion();

    const response=await fetch(
      "https://api.github.com/repos/"+UPDATE_REPO+"/releases/latest",
      {
        headers:{
          Accept:"application/vnd.github+json"
        }
      }
    );

    if(!response.ok){
      throw new Error("Could not check for the latest app release.");
    }

    const release=await response.json();

    const latestVersion=String(
      release.tag_name||""
    ).replace(/^v/i,"");

    const apk=(Array.isArray(release.assets)?release.assets:[])
      .find(
        (asset:any)=>
          String(asset.name||"")
            .toLowerCase()
            .endsWith(".apk")
      );

    if(!latestVersion||!apk?.browser_download_url){
      throw new Error("No downloadable APK was found in the latest release.");
    }

    if(compareAppVersions(latestVersion,currentVersion)<=0){
      message(
        "You are using the latest app version (v"+currentVersion+").",
        "info"
      );
      return;
    }

    const ok=window.confirm(
      "A new Shop Management version is available.\n\n"+
      "Current: v"+currentVersion+"\n"+
      "Latest: v"+latestVersion+"\n\n"+
      "Download the update now?"
    );

    if(!ok)return;

    if(Capacitor.isNativePlatform()){
      try{
        await Browser.open({
          url:String(apk.browser_download_url)
        });
      }catch{
        window.open(
          String(apk.browser_download_url),
          "_blank",
          "noopener,noreferrer"
        );
      }
    }else{
      window.open(
        String(apk.browser_download_url),
        "_blank",
        "noopener,noreferrer"
      );
    }
  }catch(e){
    message(
      e instanceof Error?e.message:String(e),
      "danger"
    );
  }
}
