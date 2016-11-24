-- UNREADY
--To be corrected check of LPT after master_reset
---------------------------------------------------------------------------------------------
-- Requirement summary:
--    [Policies] Master Reset
--
-- Description:
--    SDL receives MASTER_RESET
-- 1. Used preconditions
--    Activate app
--    Perform master_reset
--    Start SDL
--    
-- 2. Performed steps
--    Check LPT is equal to preloaded_PT
--
-- Expected result:
--    Policy Manager must revert Local Policy Table to the Preload Policy Table
---------------------------------------------------------------------------------------------

--[[ General configuration parameters ]]
Test = require('connecttest')
local config = require('config')
require('user_modules/AppTypes')

--[[ Required Shared libraries ]]
local commonFunctions = require ('user_modules/shared_testcases/commonFunctions')
local commonSteps = require ('user_modules/shared_testcases/commonSteps')

--[[ Local Variables ]]
local PATH_TO_POLICY_FILE = "files/ptu_012.json"
local DB_FALSE_VALUE = "0"
local SDLStoragePath = config.pathToSDL .. "storage/"

--[[ Local Functions ]]
function DelayedExp(time)
  local event = events.Event()
  event.matches = function(self, e) return self == e end
  EXPECT_EVENT(event, "Delayed event")
  :Timeout(time+1000)
  RUN_AFTER(function()
              RAISE_EVENT(event, event)
            end, time)
end

local function constructPathToDatabase()
  if commonSteps:file_exists(config.pathToSDL .. "storage/policy.sqlite") then
    return config.pathToSDL .. "storage/policy.sqlite"
  elseif commonSteps:file_exists(config.pathToSDL .. "policy.sqlite") then
    return config.pathToSDL .. "policy.sqlite"
  else
    commonFunctions:userPrint(31, "policy.sqlite is not found" )
    return nil
  end
end

local function executeSqliteQuery(raw_query_string, db_file_path)
  if not db_file_path then
    return nil
  end
  local query_execution_result = {}
  local query_string = table.concat({"sqlite3 ", db_file_path, " '", raw_query_string, "'"})
  local file = io.popen(query_string, 'r')
  if file then
    local index = 1
    for line in file:lines() do
      query_execution_result[index] = line
      index = index + 1
    end
    file:close()
    return query_execution_result
  else
    return nil
  end
end

local function isValuesCorrect(actual_values, expected_values)
  if #actual_values ~= #expected_values then
    return false
  end

  local tmp_expected_values = {}
  for i = 1, #expected_values do
    tmp_expected_values[i] = expected_values[i]
  end

  local is_found
  for j = 1, #actual_values do
    is_found = false
    for key, value in pairs(tmp_expected_values) do
      if value == actual_values[j] then
        is_found = true
        tmp_expected_values[key] = nil
        break
      end
    end
    if not is_found then
      return false
    end
  end
  if next(tmp_expected_values) then
    return false
  end
  return true
end

function Test.checkLocalPT()
  local expected_local_pt_request_type_values = {DB_FALSE_VALUE}
  local query_string = 'SELECT preloaded_pt FROM module_config'
  local actual_local_pt_request_type_values = executeSqliteQuery(query_string, constructPathToDatabase())
  if actual_local_pt_request_type_values then
    local result = isValuesCorrect(actual_local_pt_request_type_values, expected_local_pt_request_type_values)
    if not result then
      commonFunctions:userPrint(31, "Test failed: SDL don't change the value of preloaded_pt field to false after PTU")
    end
    return result
  else
    commonFunctions:userPrint(31, "Test failed: Can't get data from LocalPT")
    return false
  end
end

function Test:updatePolicyTable(pathToPolicyFile)
  EXPECT_HMINOTIFICATION("SDL.OnStatusUpdate")
  :ValidIf(function(exp, data)
      if (exp.occurences == 1 and data.params.status == "UPDATING") or
      (data.params.status == "UP_TO_DATE") then
        return true
      else
        local reason = "SDL.OnStatusUpdate came with wrong values. "
        if exp.occurences == 1 then
          reason = reason .. "Expected in first occurrences status 'UP_TO_DATE' or 'UPDATING', got '" .. tostring(data.params.status) .. "'"
        elseif exp.occurences == 2 then
          reason = reason .. "Expected in second occurrences status 'UP_TO_DATE', got '" .. tostring(data.params.status) .. "'"
        end
        return false, reason
      end
    end)
  :Times(Between(1,2))

  local requestId = self.hmiConnection:SendRequest("SDL.GetURLS", { service = 7 })

  EXPECT_HMIRESPONSE(requestId, {result = {code = 0, method = "SDL.GetURLS", urls = {{url = "http://policies.telematics.ford.com/api/policies"}}}})
  :Do(function(_, _)
      self.hmiConnection:SendNotification("BasicCommunication.OnSystemRequest",
        {
          requestType = "PROPRIETARY",
          fileName = "PolicyTableUpdate"
        }
      )
    end)

  EXPECT_NOTIFICATION("OnSystemRequest", { requestType = "PROPRIETARY" })
  :Do(function(_, _)
      local corIdSystemRequest = self.mobileSession:SendRPC("SystemRequest",
        {
          requestType = "PROPRIETARY",
          fileName = "PolicyTableUpdate"
        },
        pathToPolicyFile)

      EXPECT_HMICALL("BasicCommunication.SystemRequest")
      :Do(function(_, data)
          self.hmiConnection:SendResponse(data.id, "BasicCommunication.SystemRequest", "SUCCESS", {})
          self.hmiConnection:SendNotification("SDL.OnReceivedPolicyUpdate",
            {
              policyfile = "/tmp/fs/mp/images/ivsu_cache/PolicyTableUpdate"
            }
          )
        end)

      EXPECT_RESPONSE(corIdSystemRequest, { success = true, resultCode = "SUCCESS"})
      :Do(function(_, _)
          requestId = self.hmiConnection:SendRequest("SDL.GetUserFriendlyMessage", {language = "EN-US", messageCodes = {"StatusUpToDate"}})
          EXPECT_HMIRESPONSE(requestId)
        end)
    end)
end

--[[ General Precondition before ATF start ]]
commonFunctions:SDLForceStop()

--[[ Preconditions ]]
commonFunctions:newTestCasesGroup("Preconditions")

function Test:ActivationApp()
  --hmi side: sending SDL.ActivateApp request
  local RequestId = self.hmiConnection:SendRequest("SDL.ActivateApp", { appID = self.applications["Test Application"]})
  --hmi side: expect SDL.ActivateApp response
  EXPECT_HMIRESPONSE(RequestId)
  :Do(function(_,data)
    --In case when app is not allowed, it is needed to allow app
    if data.result.isSDLAllowed ~= true then
      --hmi side: sending SDL.GetUserFriendlyMessage request
      local RequestId = self.hmiConnection:SendRequest("SDL.GetUserFriendlyMessage", 
      {language = "EN-US", messageCodes = {"DataConsent"}})
      --hmi side: expect SDL.GetUserFriendlyMessage response
      --TODO: Update after resolving APPLINK-16094 EXPECT_HMIRESPONSE(RequestId,{result = {code = 0, method = "SDL.GetUserFriendlyMessage"}})
      EXPECT_HMIRESPONSE(RequestId)
      :Do(function(_,data)
        --hmi side: send request SDL.OnAllowSDLFunctionality
        self.hmiConnection:SendNotification("SDL.OnAllowSDLFunctionality", 
        {allowed = true, source = "GUI", device = {id = config.deviceMAC, name = "127.0.0.1"}})
        --hmi side: expect BasicCommunication.ActivateApp request
        EXPECT_HMICALL("BasicCommunication.ActivateApp")
        :Do(function(_,data)
          --hmi side: sending BasicCommunication.ActivateApp response
          self.hmiConnection:SendResponse(data.id,"BasicCommunication.ActivateApp", "SUCCESS", {})
        end)
        :Times(2)
      end)
      
    end
  end)
  --mobile side: expect OnHMIStatus notification
  EXPECT_NOTIFICATION("OnHMIStatus", {hmiLevel = "FULL", systemContext = "MAIN", audioStreamingState = "AUDIBLE"}) 
end

local function MASTER_RESET(self, appNumber)
  StopSDL()
  if appNumber == nil then 
    appNumber = 1
  end
  -- hmi side: sends OnExitAllApplications (SUSPENDED)
  self.hmiConnection:SendNotification("BasicCommunication.OnExitAllApplications",
    {
      reason = "MASTER_RESET"
    })
  -- hmi side: expect OnSDLClose notification
  EXPECT_HMINOTIFICATION("BasicCommunication.OnSDLClose", {})
  -- hmi side: expect OnAppUnregistered notification
  -- will be uncommented after fixinf defect: APPLINK-21931
  --EXPECT_HMINOTIFICATION("BasicCommunication.OnAppUnregistered")
      :Times(1)
  DelayedExp(1000)
end

------------------------------------------------------------------------------------------------------
-- Test case Check 10
-- Stop SDL with MASTER_RESET -> check absence of policy.sqlite file ==> file is absent
-- send master reset  
function Test:ExecuteMasterReset() 
       MASTER_RESET(self)
end

-- check absence of policy.sqlite file, file should be absent
function Test:CheckAbsenceOfPolisyTable()
  local returnValue
     if commonSteps.file_exists(SDLStoragePath .. "policy.sqlite") == false then
   self:FailTestCase("policy.sqlite should be absent")
    end
end

------------------------------------------------------------------------------------------------------
-- Test case Check 11
-- Start SDL (check SDL correctly loads preloaded_pt) -> check preloaded_pt FROM module_config ==> value is "1"
function Test:RestartSDL()
  StartSDLAfterStop("TestCaseCheck11", false)
  end

-- check preloaded_pt FROM module_config, value should be "1"
function Test:CheckValueOfPreloaded11()  
  preloaded_pt = get_preloaded_pt_value()

  if (preloaded_pt == 0) then
    -- commonFunctions:userPrint(31, "preloaded_pt in localPT is 0, should be 1")
    self:FailTestCase("preloaded_pt in localPT is 0, should be 1")
  end
end

--[[ Test ]]
commonFunctions:newTestCasesGroup("Test")

function Test:Test()
  os.execute("sleep 3")
  self.checkLocalPT()
end

--[[ Postconditions ]]
commonFunctions:newTestCasesGroup("Postconditions")

function Test:Postcondition()
  commonSteps:DeletePolicyTable(self)
end

commonFunctions:SDLForceStop()
return Test