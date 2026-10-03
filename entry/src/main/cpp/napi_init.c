#include <napi/native_api.h>
#include <stdlib.h>
#include <unistd.h>
#include "flclash_core.h"

static char *ReadString(napi_env env, napi_value value)
{
    size_t size = 0;
    if (napi_get_value_string_utf8(env, value, NULL, 0, &size) != napi_ok) {
        napi_throw_type_error(env, NULL, "Expected a string");
        return NULL;
    }
    char *result = (char *)malloc(size + 1);
    if (result == NULL) {
        napi_throw_error(env, NULL, "Out of memory");
        return NULL;
    }
    if (napi_get_value_string_utf8(env, value, result, size + 1, &size) != napi_ok) {
        free(result);
        napi_throw_type_error(env, NULL, "Invalid string");
        return NULL;
    }
    return result;
}

static napi_value ReturnString(napi_env env, char *value)
{
    napi_value result;
    napi_create_string_utf8(env, value ? value : "", NAPI_AUTO_LENGTH, &result);
    if (value) {
        FlClashFree(value);
    }
    return result;
}

static napi_value Launch(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    if (argc != 2) {
        napi_throw_type_error(env, NULL, "launch(homeDir, secret) requires two arguments");
        return NULL;
    }
    char *home = ReadString(env, args[0]);
    if (home == NULL) {
        return NULL;
    }
    char *secret = ReadString(env, args[1]);
    if (secret == NULL) {
        free(home);
        return NULL;
    }
    char *error = FlClashLaunch(home, secret);
    free(home);
    free(secret);
    return ReturnString(env, error);
}

static napi_value StartTun(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, NULL, NULL);
    int32_t fd = -1;
    if (argc != 1 || napi_get_value_int32(env, arg, &fd) != napi_ok || fd < 0) {
        napi_throw_type_error(env, NULL, "startTun requires a valid file descriptor");
        return NULL;
    }
    napi_value result;
    napi_get_boolean(env, FlClashStartTun(fd) == 1, &result);
    return result;
}

static napi_value GetTunError(napi_env env, napi_callback_info info)
{
    return ReturnString(env, FlClashGetTunError());
}

typedef struct {
    napi_async_work work;
    napi_deferred deferred;
    char *home;
    char *secret;
    char *error;
    int32_t fd;
    int started;
    int launch;
    unsigned long long epoch;
} CoreWork;

static void ExecuteCoreWork(napi_env env, void *data)
{
    CoreWork *request = (CoreWork *)data;
    if (request->launch == 4) {
        FlClashStopAtEpoch(request->epoch);
    } else if (request->launch == 3) {
        request->error = FlClashTestProfileDelay(request->home, request->secret);
    } else if (request->launch == 2) {
        request->error = FlClashInspectProfile(request->home);
    } else if (request->launch) {
        request->error = FlClashLaunchAtEpoch(request->home, request->secret, request->epoch);
    } else {
        request->started = FlClashStartTunAtEpoch(request->fd, request->epoch);
        request->fd = -1;
    }
}

static void CompleteCoreWork(napi_env env, napi_status status, void *data)
{
    CoreWork *request = (CoreWork *)data;
    napi_value result;
    if (request->launch == 4) {
        napi_get_undefined(env, &result);
    } else if (request->launch) {
        napi_create_string_utf8(env, request->error ? request->error : "", NAPI_AUTO_LENGTH, &result);
    } else {
        napi_get_boolean(env, request->started == 1, &result);
    }
    if (status == napi_ok) {
        napi_resolve_deferred(env, request->deferred, result);
    } else {
        napi_value reason;
        napi_create_string_utf8(env, "Native core worker failed", NAPI_AUTO_LENGTH, &reason);
        napi_reject_deferred(env, request->deferred, reason);
    }
    if (request->error) { FlClashFree(request->error); }
    free(request->home);
    free(request->secret);
    if (!request->launch && request->fd >= 0) { close(request->fd); }
    napi_delete_async_work(env, request->work);
    free(request);
}

static napi_value QueueCoreWork(napi_env env, CoreWork *request)
{
    napi_value promise;
    napi_value resource;
    if (request->launch != 4) { request->epoch = FlClashLifecycleEpoch(); }
    napi_create_promise(env, &request->deferred, &promise);
    napi_create_string_utf8(env, "FlClash core", NAPI_AUTO_LENGTH, &resource);
    if (napi_create_async_work(env, NULL, resource, ExecuteCoreWork, CompleteCoreWork,
        request, &request->work) != napi_ok || napi_queue_async_work(env, request->work) != napi_ok) {
        if (request->work) { napi_delete_async_work(env, request->work); }
        free(request->home);
        free(request->secret);
        if (!request->launch && request->fd >= 0) { close(request->fd); }
        free(request);
        napi_throw_error(env, NULL, "Could not queue native core work");
        return NULL;
    }
    return promise;
}

static napi_value LaunchAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    if (argc != 2) {
        napi_throw_type_error(env, NULL, "launchAsync(homeDir, secret) requires two arguments");
        return NULL;
    }
    CoreWork *request = (CoreWork *)calloc(1, sizeof(CoreWork));
    if (!request) {
        napi_throw_error(env, NULL, "Out of memory");
        return NULL;
    }
    request->home = ReadString(env, args[0]);
    if (!request->home) {
        free(request);
        return NULL;
    }
    request->secret = ReadString(env, args[1]);
    if (!request->secret) {
        free(request->home);
        free(request);
        return NULL;
    }
    request->launch = 1;
    return QueueCoreWork(env, request);
}

static napi_value TestProfileDelay(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    if (argc != 2) {
        napi_throw_type_error(env, NULL, "testProfileDelay(content, name) requires two arguments");
        return NULL;
    }
    CoreWork *request = (CoreWork *)calloc(1, sizeof(CoreWork));
    if (!request) {
        napi_throw_error(env, NULL, "Out of memory");
        return NULL;
    }
    request->home = ReadString(env, args[0]);
    if (!request->home) {
        free(request);
        return NULL;
    }
    request->secret = ReadString(env, args[1]);
    if (!request->secret) {
        free(request->home);
        free(request);
        return NULL;
    }
    request->launch = 3;
    return QueueCoreWork(env, request);
}

static napi_value StartTunAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, NULL, NULL);
    int32_t fd = -1;
    if (argc != 1 || napi_get_value_int32(env, arg, &fd) != napi_ok || fd < 0) {
        napi_throw_type_error(env, NULL, "startTunAsync requires a valid file descriptor");
        return NULL;
    }
    CoreWork *request = (CoreWork *)calloc(1, sizeof(CoreWork));
    if (!request) {
        napi_throw_error(env, NULL, "Out of memory");
        return NULL;
    }
    request->fd = fd;
    return QueueCoreWork(env, request);
}

static napi_value Stop(napi_env env, napi_callback_info info)
{
    FlClashStop();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value StopAsync(napi_env env, napi_callback_info info)
{
    CoreWork *request = (CoreWork *)calloc(1, sizeof(CoreWork));
    if (!request) {
        napi_throw_error(env, NULL, "Out of memory");
        return NULL;
    }
    request->launch = 4;
    // Invalidate pending starts now, before this stop enters the worker queue.
    request->epoch = FlClashCancelLifecycle();
    return QueueCoreWork(env, request);
}

static napi_value Invoke(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, NULL, NULL);
    if (argc != 1) {
        napi_throw_type_error(env, NULL, "invoke requires one string");
        return NULL;
    }
    char *input = ReadString(env, arg);
    if (input == NULL) {
        return NULL;
    }
    char *output = FlClashInvoke(input);
    free(input);
    return ReturnString(env, output);
}

static napi_value InspectProfile(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, NULL, NULL);
    if (argc != 1) { napi_throw_type_error(env, NULL, "inspectProfile requires content"); return NULL; }
    CoreWork *request = (CoreWork *)calloc(1, sizeof(CoreWork));
    if (!request) { napi_throw_error(env, NULL, "Out of memory"); return NULL; }
    request->home = ReadString(env, arg);
    if (!request->home) { free(request); return NULL; }
    request->launch = 2;
    return QueueCoreWork(env, request);
}


static napi_value BeginDelayJob(napi_env env, napi_callback_info info) {
    size_t argc=2; napi_value args[2]; napi_get_cb_info(env,info,&argc,args,NULL,NULL);
    if(argc!=2) {napi_throw_type_error(env,NULL,"beginDelayJob requires content and names");return NULL;}
    char *content=ReadString(env,args[0]); if(!content)return NULL;
    char *names=ReadString(env,args[1]); if(!names){free(content);return NULL;}
    char *output=FlClashBeginDelayJob(content,names);free(content);free(names);
    return ReturnString(env,output);
}
static napi_value PollDelayJob(napi_env env, napi_callback_info info) {
    size_t argc=1;napi_value arg;napi_get_cb_info(env,info,&argc,&arg,NULL,NULL);
    if(argc!=1){napi_throw_type_error(env,NULL,"pollDelayJob requires id");return NULL;}
    char *id=ReadString(env,arg);if(!id)return NULL;
    char *output=FlClashPollDelayJob(id);free(id);return ReturnString(env,output);
}
static napi_value CancelDelayJob(napi_env env, napi_callback_info info) {
    size_t argc=1;napi_value arg;napi_get_cb_info(env,info,&argc,&arg,NULL,NULL);
    if(argc!=1){napi_throw_type_error(env,NULL,"cancelDelayJob requires id");return NULL;}
    char *id=ReadString(env,arg);if(!id)return NULL;
    FlClashCancelDelayJob(id);free(id);napi_value result;napi_get_undefined(env,&result);return result;
}

static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor methods[] = {
        {"beginDelayJob", NULL, BeginDelayJob, NULL, NULL, NULL, napi_default, NULL},
        {"pollDelayJob", NULL, PollDelayJob, NULL, NULL, NULL, napi_default, NULL},
        {"cancelDelayJob", NULL, CancelDelayJob, NULL, NULL, NULL, napi_default, NULL},
        {"testProfileDelay", NULL, TestProfileDelay, NULL, NULL, NULL, napi_default, NULL},
        {"inspectProfile", NULL, InspectProfile, NULL, NULL, NULL, napi_default, NULL},
        {"launch", NULL, Launch, NULL, NULL, NULL, napi_default, NULL},
        {"startTun", NULL, StartTun, NULL, NULL, NULL, napi_default, NULL},
        {"getTunError", NULL, GetTunError, NULL, NULL, NULL, napi_default, NULL},
        {"launchAsync", NULL, LaunchAsync, NULL, NULL, NULL, napi_default, NULL},
        {"startTunAsync", NULL, StartTunAsync, NULL, NULL, NULL, napi_default, NULL},
        {"stop", NULL, Stop, NULL, NULL, NULL, napi_default, NULL},
        {"stopAsync", NULL, StopAsync, NULL, NULL, NULL, napi_default, NULL},
        {"invoke", NULL, Invoke, NULL, NULL, NULL, napi_default, NULL},
    };
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
    return exports;
}

static napi_module module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = Init,
    .nm_modname = "flclash_napi",
    .nm_priv = NULL,
    .reserved = {0},
};

__attribute__((constructor)) void RegisterFlClashNapi(void)
{
    napi_module_register(&module);
}
