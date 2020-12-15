import ballerina/config;
import ballerina/http;
import ballerina/log;
import ballerina/runtime;
import ballerina_stdlib/commons;

import ballerina/io;

http:ClientConfiguration clientConfig = {
    retryConfig: {
        count: commons:RETRY_COUNT,
		intervalInMillis: commons:RETRY_INTERVAL,
		backOffFactor: commons:RETRY_BACKOFF_FACTOR,
		maxWaitIntervalInMillis: commons:RETRY_MAX_WAIT_TIME
    }
};
http:Client httpClient = new (commons:API_PATH, clientConfig);
string accessToken = config:getAsString(commons:ACCESS_TOKEN_ENV);
string accessTokenHeaderValue = "Bearer " + accessToken;

boolean isFailure = false;

public function main() {
    json[] modulesJson = commons:getModuleJsonArray();
    commons:Module[] modules = commons:getModuleArray(modulesJson);
    commons:addDependentModules(modules);

    log:printInfo("Publishing all the standard library snapshots");
    checkCurrentPublishWorkflows();
    handlePublish(modules);

    if (isFailure) {
        commons:logNewLine();
        error err = error("PublishFailed", message = "Some module builds are failing");
        commons:logAndPanicError("Publishing Failed.", err);
    }
}

function handlePublish(commons:Module[] modules) {
    int currentLevel = -1;
    commons:Module[] currentModules = [];
    foreach commons:Module module in modules {
        int nextLevel = module.level;
        if (nextLevel > currentLevel) {
            waitForCurrentLevelModuleBuild(currentModules, currentLevel);
            commons:logNewLine();
            log:printInfo("Publishing level " + nextLevel.toString() + " modules");
            currentModules.removeAll();
        }
        boolean inProgress = commons:publishModule(module, accessTokenHeaderValue, httpClient);
        if (inProgress) {
            module.inProgress = inProgress;
            currentModules.push(module);
            log:printInfo("Successfully triggerred the module \"" + commons:getModuleName(module) + "\"");
        } else {
            log:printWarn("Failed to trigger the module \"" + commons:getModuleName(module) + "\"");
        }
        currentLevel = nextLevel;
    }
    waitForCurrentLevelModuleBuild(currentModules, currentLevel);
}

function waitForCurrentLevelModuleBuild(commons:Module[] modules, int level) {
    if (modules.length() == 0) {
        return;
    }
    commons:logNewLine();
    log:printInfo("Waiting for level " + level.toString() + " module builds");
    runtime:sleep(commons:SLEEP_INTERVAL); // sleep first to make sure we get the latest workflow triggered by this job
    commons:Module[] unpublishedModules = modules.filter(
        function (commons:Module m) returns boolean {
            return m.inProgress;
        }
    );
    commons:Module[] publishedModules = [];

    boolean allModulesPublished = false;
    int waitCycles = 0;
    while (!allModulesPublished) {
        foreach commons:Module module in modules {
            if (module.inProgress) {
                checkInProgressModules(module, unpublishedModules, publishedModules);
            }
        }
        if (publishedModules.length() == modules.length()) {
            allModulesPublished = true;
        } else if (waitCycles < commons:MAX_WAIT_CYCLES) {
            runtime:sleep(commons:SLEEP_INTERVAL);
            waitCycles += 1;
        } else {
            break;
        }
    }
    if (unpublishedModules.length() > 0) {
        log:printWarn("Following modules not published after the max wait time");
        commons:printModules(unpublishedModules);
        error err = error("Unpublished", message = "There are modules not published after max wait time");
        commons:logAndPanicError("Publishing Failed.", err);
    }
}

function checkInProgressModules(commons:Module module, commons:Module[] unpublished, commons:Module[] published) {
    boolean publishCompleted = checkModulePublish(module);
    if (publishCompleted) {
        module.inProgress = !publishCompleted;
        var moduleIndex = unpublished.indexOf(module);
        if (moduleIndex is int) {
            commons:Module publishedModule = unpublished.remove(moduleIndex);
            published.push(publishedModule);
        }
    }
}

function checkModulePublish(commons:Module module) returns boolean {
    http:Request request = commons:createRequest(accessTokenHeaderValue);
    string moduleName = module.name.toString();
    string apiPath = "/" + moduleName + "/" + commons:WORKFLOW_STATUS_PATH;
    // Hack for type casting error in HTTP Client
    // https://github.com/ballerina-platform/ballerina-standard-library/issues/566
    var result = trap httpClient->get(apiPath, request);
    if (result is error) {
        log:printWarn("Error occurred while checking the publish status for module: " + commons:getModuleName(module));
        return false;
    }
    http:Response response = <http:Response>result;
    boolean isValid = commons:validateResponse(response);
    if (isValid) {
        map<json> payload = commons:getJsonPayload(response);
        if (commons:isWorkflowCompleted(payload)) {
            checkWorkflowRun(payload, module);
            return true;
        }
    }
    return false;
}

function checkCurrentPublishWorkflows() {
    io:println("Checking for already running workflows");
    http:Request request = commons:createRequest(accessTokenHeaderValue);
    string apiPath = "/ballerina-standard-library/actions/workflows/publish_snapshots.yml/runs?per_page=1";
    var result = trap httpClient->get(apiPath, request);
    if (result is error) {
        log:printWarn("Error occurred while checking the current workflow status");
    }
    io:println("Response Received");
    http:Response response = <http:Response>result;
    boolean isValid = commons:validateResponse(response);
    if (isValid) {
        map<json> payload = commons:getJsonPayload(response);
        if (!commons:isWorkflowCompleted(payload)) {
            map<json> workflow = commons:getWorkflowJsonObject(payload);
            io:println(workflow.id);
            string cancelPath = "/ballerina-standard-library/actions/runs/" + workflow.id.toString() + "/cancel";
            var cancelResult = trap httpClient->post(cancelPath, request);
            if (cancelResult is error) {
                log:printWarn("Error occurred while cancelling the current workflow status");
            } else {
                io:println(cancelResult.getJsonPayload());
                io:println(cancelResult.statusCode);
                log:printInfo("Cancelled the already running job.");
            }
        } else {
            io:println("No workflows running");
        }
    }
}

function checkWorkflowRun(map<json> payload, commons:Module module) {
    map<json> workflowRun = commons:getWorkflowJsonObject(payload);
    string status = workflowRun.conclusion.toString();
    if (status == CONCLUSION_SUCCSESS) {
        log:printInfo("Succcessfully published the module \"" + commons:getModuleName(module) + "\"");
    } else {
        isFailure = true;
        log:printWarn("Failed to publish the module \"" + commons:getModuleName(module) + "\". Conclusion: " + status);
    }
}
