---------------------------------------------------------------------------------------------
-- Requirement summary:
--    [GENIVI] Conditions for SDL to create and use 'AppIconsFolder' storage 
--    [AppIconsFolder]: SDL must check whether folder defined at "AppIconsFolder" param exists and has read-write permissions
--  
-- Description:
--    SDL checks and finds icon related to app if such icons exist
-- 1. Used preconditions:
--      Delete files and policy table from previous ignition cycle if any
--      Set  SDL "storage" as AppiconsFolder in .ini file
--      Start SDL and HMI
-- 2. Performed steps:
--      Register app
--      Send SetAppIcon with appid as icon name
-- Expected result:
--      SDL correctly finds app related icons
---------------------------------------------------------------------------------------------
--[[ General configuration parameters ]]
config.deviceMAC = "12ca17b49af2289436f303e0166030a21e525d266e209267433801a8fd4071a0"

--[[ General Settings for configuration ]]
local preconditions = require('user_modules/shared_testcases/commonPreconditions')
preconditions:Connecttest_without_ExitBySDLDisconnect_WithoutOpenConnectionRegisterApp("connecttestIcons.lua")
Test = require('user_modules/connecttestIcons')
require('cardinalities')
local mobile_session = require('mobile_session')

--[[ Required Shared Libraries ]]
local commonFunctions = require('user_modules/shared_testcases/commonFunctions')
local commonSteps = require('user_modules/shared_testcases/commonSteps')
require('user_modules/AppTypes')

--[[ Local variables ]]
local pathToAppFolder
local file
local RAIParameters = config.application1.registerAppInterfaceParams

--[[ Local functions ]]
local function registerApplication(self)
  local corIdRAI = self.mobileSession:SendRPC("RegisterAppInterface", RAIParameters)
  EXPECT_HMINOTIFICATION("BasicCommunication.OnAppRegistered",
  {
    application =
    {
     appName = RAIParameters.appName
    }
  })
  :Do(function(_,data)
    self.applications[RAIParameters.appName] = data.params.application.appID
  end)
  self.mobileSession:ExpectResponse(corIdRAI, { success = true, resultCode = "SUCCESS" })
end

local function checkFilePresent(name, messages)
  file = io.open(name,"r")
  if file ~= nil then
    io.close(file)
    if messages == true then
      commonFunctions:userPrint(32, "File " .. tostring(name) .. " exists")
    end
    return true
  else
    if messages == true then
      commonFunctions:userPrint(31, "File " .. tostring(name) .. " does not exist")
    end
    return false
  end
end

-- Generate path to application folder
local function pathToAppFolderFunction(appID)
  commonSteps:CheckSDLPath()
  local path = config.pathToSDL .. tostring("storage/") .. tostring(appID) .. "_" .. tostring(config.deviceMAC) .. "/"
  return path
end

--[[ Preconditions ]]
commonSteps:DeleteLogsFileAndPolicyTable()
commonFunctions:newTestCasesGroup("Preconditions")

 function Test.Precondition_stopSDL()
  StopSDL()
 end  

function Test.Precondition_configureAppIconsFolder()
  commonFunctions:SetValuesInIniFile("AppIconsFolder%s-=%s-.-%s-\n", "AppIconsFolder", 'storage')
end

 function Test.Precondition_startSDL()
  StartSDL(config.pathToSDL, config.ExitOnCrash)
 end

 function Test:Precondition_initHMI()
  self:initHMI()
 end

 function Test:Precondition_initHMIonReady()
  self:initHMI_onReady()
 end

 function Test:Precondition_connectMobile()
  self:connectMobile()
 end

function Test.Precondition_removeAppIconsFolder()
  local addedFolderInScript = "storage"
  local existsResult = commonSteps:Directory_exist(tostring(config.pathToSDL .. addedFolderInScript))
  if existsResult == true then
    local rmAppIconsFolder  = assert( os.execute( "rm -rf " .. tostring(config.pathToSDL .. addedFolderInScript)))
    if rmAppIconsFolder ~= true then
      commonFunctions:userPrint(31, tostring(addedFolderInScript) .. " folder is not deleted")
    end
  end
end

--[[ Test ]]
commonFunctions:newTestCasesGroup("Test")

function Test:Check_SDL_finds_icons_saved_in_AppIconsFolder()
local SDLStoragePath = config.pathToSDL .. "storage/"
  local RAIParams
  RAIParams = config.application1.registerAppInterfaceParams
  RAIParams.appName = "Awesome Music App"
  RAIParams.appID = "853426"
  pathToAppFolder = pathToAppFolderFunction(RAIParams.appID)
  self.mobileSession= mobile_session.MobileSession(self, self.mobileConnection)
  self.mobileSession.version = 4
  self.mobileSession:StartService(7)
  :Do(function()
    registerApplication(self)
    EXPECT_NOTIFICATION("OnHMIStatus", { systemContext = "MAIN", hmiLevel = "NONE", audioStreamingState = "NOT_AUDIBLE"})
     :Do(function()
     local cidPutFile = self.mobileSession:SendRPC("PutFile",
       {
         syncFileName = "icon.png",
         fileType = "GRAPHIC_PNG",
         persistentFile = false,
         systemFile = false
       }, "files/icon.png")
     EXPECT_RESPONSE(cidPutFile, { success = true, resultCode = "SUCCESS" })
     :Do(function()
       local cidSetAppIcon = self.mobileSession:SendRPC("SetAppIcon",{ syncFileName = "icon.png" })
        EXPECT_HMICALL("UI.SetAppIcon",
         {
           syncFileName =
            {
              imageType = "DYNAMIC",
              value = pathToAppFolder .. "icon.png"
            }
         })
         :Do(function(_,data)
           self.hmiConnection:SendResponse(data.id, data.method, "SUCCESS", {})
          end)
         EXPECT_RESPONSE(cidSetAppIcon, { resultCode = "SUCCESS", success = true })
         :ValidIf(function()
            local FileToCheck = SDLStoragePath .. tostring(RAIParams.appID)
            local fileExistsResult = checkFilePresent(FileToCheck, true)
            return fileExistsResult
          end)
         end)
       end)
    end)
end

--[[ Postconditions ]]
commonFunctions:newTestCasesGroup("Postconditions")
function Test.Postcondition_removeSpecConnecttest()
  os.execute(" rm -f  ./user_modules/connecttestIcons.lua")
end 

function Test.Postcondition_stopSDL()
  StopSDL()
end
