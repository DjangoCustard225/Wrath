#include "WrathBridge.h"
#ifdef __APPLE__
#include <Python/Python.h>
#else
#include <Python.h>
#endif
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>

typedef struct {
    WrathToken *token;
    WrathEvent callback;
    void *context;
} RuntimeOperation;
static _Thread_local RuntimeOperation *current_operation;
static pthread_mutex_t initialization_lock = PTHREAD_MUTEX_INITIALIZER;

static RuntimeOperation *operation_from(PyObject *capsule) {
    if(!capsule || capsule == Py_None) return current_operation;
    return PyCapsule_GetPointer(capsule, "WrathOperation");
}
static PyObject *operation_context(PyObject *self, PyObject *args) {
    if(!current_operation) Py_RETURN_NONE;
    return PyCapsule_New(current_operation, "WrathOperation", NULL);
}
static PyObject *cancelled(PyObject *self, PyObject *args) {
    PyObject *capsule=Py_None;
    if(!PyArg_ParseTuple(args,"|O",&capsule)) return NULL;
    RuntimeOperation *operation=operation_from(capsule);
    if(PyErr_Occurred()) return NULL;
    return PyBool_FromLong(operation && wrath_is_cancelled(operation->token));
}
static PyObject *checkpoint(PyObject *self, PyObject *args) {
    PyObject *capsule=Py_None;
    if(!PyArg_ParseTuple(args,"|O",&capsule)) return NULL;
    RuntimeOperation *operation=operation_from(capsule);
    if(PyErr_Occurred()) return NULL;
    int stopped=0;
    // A paused transfer must not hold the GIL and starve link inspections.
    Py_BEGIN_ALLOW_THREADS
    if(operation) stopped=wrath_wait_if_paused(operation->token);
    Py_END_ALLOW_THREADS
    return PyBool_FromLong(stopped);
}
static PyObject *report(PyObject *self, PyObject *args) {
    PyObject *capsule;
    const char *json;
    if(!PyArg_ParseTuple(args,"Os",&capsule,&json)) return NULL;
    RuntimeOperation *operation=operation_from(capsule);
    if(PyErr_Occurred()) return NULL;
    if(operation && operation->callback) {
        Py_BEGIN_ALLOW_THREADS
        operation->callback(json,operation->context);
        Py_END_ALLOW_THREADS
    }
    Py_RETURN_NONE;
}
static PyMethodDef methods[] = {
    {"context",operation_context,METH_NOARGS,"Capture this operation for downloader hooks"},
    {"cancelled",cancelled,METH_VARARGS,"Check operation cancellation"},
    {"checkpoint",checkpoint,METH_VARARGS,"Wait while paused without holding the GIL"},
    {"report",report,METH_VARARGS,"Send structured progress to the native UI"},
    {NULL,NULL,0,NULL}
};
static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "wrath_native", NULL, -1, methods};
static PyObject *PyInit_wrath_native(void) { return PyModule_Create(&module); }
static int initialized;
static int module_registered;
static char *startup_error;

// Startup failures happen before json (or even encodings) can be imported.
static char *error_json(const char *message) {
    size_t length=strlen(message);
    char *result=malloc(length*6+16), *out=result;
    if(!result) return NULL;
    memcpy(out,"{\"error\":\"",10); out+=10;
    for(const unsigned char *p=(const unsigned char *)message;*p;p++) {
        if(*p=='"' || *p=='\\') { *out++='\\'; *out++=*p; }
        else if(*p<32) { snprintf(out,7,"\\u%04x",*p); out+=6; }
        else *out++=*p;
    }
    memcpy(out,"\"}",3);
    return result;
}

static PyStatus append_path(PyConfig *config, const char *path) {
    wchar_t *wide=Py_DecodeLocale(path,NULL);
    if(!wide) return PyStatus_NoMemory();
    PyStatus status=PyWideStringList_Append(&config->module_search_paths,wide);
    PyMem_RawFree(wide);
    return status;
}

static int ensure_standard_descriptors(void) {
    // A GUI process may start with closed console descriptors. CPython's iOS
    // log setup reads sys.stderr.errors; a closed fd would make stderr None.
    for(int descriptor=STDIN_FILENO;descriptor<=STDERR_FILENO;descriptor++) {
        if(fcntl(descriptor,F_GETFD)!=-1 || errno!=EBADF) continue;
        int replacement=open("/dev/null",descriptor==STDIN_FILENO ? O_RDONLY : O_WRONLY);
        if(replacement<0) return -1;
        if(replacement!=descriptor) {
            int result=dup2(replacement,descriptor); close(replacement);
            if(result<0) return -1;
        }
    }
    return 0;
}

static char *initialize(const char *root) {
    char home[4096], stdlib[4096], dynamic[4096], packages[4096], executable[4096], landmark[4096];
    if(snprintf(home,sizeof(home),"%s/python",root)>=(int)sizeof(home) ||
       snprintf(stdlib,sizeof(stdlib),"%s/lib/python3.13",home)>=(int)sizeof(stdlib) ||
       snprintf(dynamic,sizeof(dynamic),"%s/lib-dynload",stdlib)>=(int)sizeof(dynamic) ||
       snprintf(packages,sizeof(packages),"%s/packages",root)>=(int)sizeof(packages) ||
       snprintf(executable,sizeof(executable),"%s/Wrath",root)>=(int)sizeof(executable) ||
       snprintf(landmark,sizeof(landmark),"%s/encodings/__init__.py",stdlib)>=(int)sizeof(landmark))
        return error_json("The app's bundled runtime path is too long.");
    if(access(landmark,R_OK)!=0)
        return error_json("This app build is missing Python's standard library (python/lib/python3.13/encodings/__init__.py). Install the complete Wrath IPA.");
    if(startup_error) return error_json(startup_error);
    if(ensure_standard_descriptors()<0)
        return error_json("Could not initialize the Python runtime's standard streams.");
    if(!module_registered) {
        if(PyImport_AppendInittab("wrath_native",PyInit_wrath_native)<0)
            return error_json("Could not register the native extraction bridge.");
        module_registered=1;
    }
    PyPreConfig preconfig; PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode=1; preconfig.configure_locale=0;
    PyStatus status=Py_PreInitialize(&preconfig);
    if(PyStatus_Exception(status)) goto preinit_failed;
    PyConfig config; PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode=0; config.install_signal_handlers=0;
    config.parse_argv=0; config.site_import=0; config.configure_c_stdio=0;
    // Set the complete path configuration before Python imports encodings.
    // iOS framework builds must not discover paths from desktop build prefixes.
#define SET_CONFIG(field, value) do { status=PyConfig_SetBytesString(&config,&config.field,value); if(PyStatus_Exception(status)) goto config_failed; } while(0)
    SET_CONFIG(home,home);
    SET_CONFIG(prefix,home); SET_CONFIG(base_prefix,home);
    SET_CONFIG(exec_prefix,home); SET_CONFIG(base_exec_prefix,home);
    SET_CONFIG(stdlib_dir,stdlib);
    SET_CONFIG(executable,executable); SET_CONFIG(base_executable,executable);
    SET_CONFIG(program_name,executable);
    SET_CONFIG(filesystem_encoding,"utf-8"); SET_CONFIG(filesystem_errors,"surrogateescape");
    SET_CONFIG(stdio_encoding,"utf-8"); SET_CONFIG(stdio_errors,"backslashreplace");
#undef SET_CONFIG
    const char *paths[]={stdlib,dynamic,packages,root};
    for(size_t i=0;i<sizeof(paths)/sizeof(paths[0]);i++) {
        status=append_path(&config,paths[i]); if(PyStatus_Exception(status)) goto config_failed;
    }
    config.module_search_paths_set=1;
    status=Py_InitializeFromConfig(&config);
config_failed:
    // PyConfig_Clear may release memory referenced by a failure status.
    if(PyStatus_Exception(status)) {
        char message[2048];
        snprintf(message,sizeof(message),"Python startup failed%s%s: %s",status.func ? " in " : "",status.func ? status.func : "",status.err_msg ? status.err_msg : "initialization exited unexpectedly");
        startup_error=strdup(message);
        PyConfig_Clear(&config);
        return error_json(startup_error ? startup_error : "Python startup failed.");
    }
    PyConfig_Clear(&config);
    initialized=1;
    PyEval_SaveThread();
    return NULL;
preinit_failed:
    return error_json(status.err_msg ? status.err_msg : "Python pre-initialization failed.");
}

static char *failure(const char *message) {
    PyObject *exception=PyErr_GetRaisedException();
    PyObject *description=exception ? PyObject_Str(exception) : NULL;
    const char *detail=description ? PyUnicode_AsUTF8(description) : NULL;
    char combined[2048];
    snprintf(combined,sizeof(combined),"%s%s%s",message,detail ? ": " : "",detail ? detail : "");
    char *result=error_json(combined);
    Py_XDECREF(description); Py_XDECREF(exception); PyErr_Clear(); return result;
}
static char *invoke_worker(const char *root,const char *request,WrathToken *token,
                           const char *method,WrathEvent callback,void *context) {
    pthread_mutex_lock(&initialization_lock);
    char *error=NULL;
    if(!initialized) error=initialize(root);
    pthread_mutex_unlock(&initialization_lock);
    if(error) return error;
    PyGILState_STATE gil=PyGILState_Ensure();
    RuntimeOperation operation={token,callback,context};
    current_operation=&operation;
    char *result=NULL;
    PyObject *worker=PyImport_ImportModule("wrath_worker");
    if(!worker) {
        result=failure("Could not load the bundled extraction engine");
    } else {
        PyObject *out=PyObject_CallMethod(worker,method,"s",request);
        Py_DECREF(worker);
        if(!out) result=failure("The extraction engine stopped unexpectedly");
        else {
            const char *utf8=PyUnicode_AsUTF8(out);
            result=utf8 ? strdup(utf8) : failure("Invalid extraction result.");
            Py_DECREF(out);
        }
    }
    current_operation=NULL;
    PyGILState_Release(gil);
    return result;
}
char *wrath_extract(const char *root,const char *cache,const char *request,WrathToken *token) {
    return invoke_worker(root,request,token,"extract",NULL,NULL);
}
char *wrath_download(const char *root,const char *request,WrathToken *token,WrathEvent callback,void *context) {
    return invoke_worker(root,request,token,"download",callback,context);
}
