/*
 * Copyright (c) 2026, The NAITAE authors.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  The NAITAE authors designate
 * this particular file as subject to the "Classpath" exception as provided
 * in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 */

/*
 * Native method registration for java.lang.rv.IndexingTree.
 */

#include "jni.h"
#include "jni_util.h"
#include "jvm.h"

static JNINativeMethod methods[] = {
    {"init",          "(I)V",                                (void *)&JVM_IndexingTreeInit},
    {"allocateTable",   "(I)[Ljava/lang/rv/IndexingTreeEntry;", (void *)&JVM_IndexingTreeAllocTable},
    {"adjustCapacity0", "(III)V",                                (void *)&JVM_IndexingTreeAdjustCapacity},
};

JNIEXPORT void JNICALL
Java_java_lang_rv_IndexingTree_registerNatives(JNIEnv *env, jclass cls)
{
    (*env)->RegisterNatives(env, cls,
                            methods, sizeof(methods)/sizeof(methods[0]));
}
