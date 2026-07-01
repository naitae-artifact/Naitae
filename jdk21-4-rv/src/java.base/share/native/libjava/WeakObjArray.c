/*
 * Native method registration for java.lang.rv.WeakObjArray.
 */

#include "jni.h"
#include "jni_util.h"
#include "jvm.h"

static JNINativeMethod methods[] = {
    {"allocate", "(I)[Ljava/lang/Object;", (void *)&JVM_WeakObjArrayAllocate},
};

JNIEXPORT void JNICALL
Java_java_lang_rv_WeakObjArray_registerNatives(JNIEnv *env, jclass cls)
{
    (*env)->RegisterNatives(env, cls,
                            methods, sizeof(methods)/sizeof(methods[0]));
}
