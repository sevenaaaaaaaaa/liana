/* Liana Android JNI 垫片
 *
 * 设计原则（与 macOS build.sh 的"手工 bundle"一致）：
 * - Rust 侧 liana-ffi 保持纯 C ABI（liana.h），零 JNI 依赖；
 * - 本文件是唯一的 JNI 边界：Java_dev_liana_ime_LianaJni_* → liana.h；
 * - 静态链接 libliana_ffi.a，产出自包含的 libliana_jni.so。
 *
 * 会话句柄以 jlong 传递（指针数值），Kotlin 侧不解析只透传。
 */
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "liana.h"

static jstring to_jstring(JNIEnv *env, char *s) {
    jstring result = s ? (*env)->NewStringUTF(env, s) : NULL;
    liana_free_string(s);
    return result;
}

static char *to_chars(JNIEnv *env, jstring js) {
    if (js == NULL) return NULL;
    const char *utf = (*env)->GetStringUTFChars(env, js, NULL);
    if (utf == NULL) return NULL;
    char *copy = strdup(utf);
    (*env)->ReleaseStringUTFChars(env, js, utf);
    return copy;
}

#define SESSION ((LianaSession *)(intptr_t)session)

JNIEXPORT jlong JNICALL
Java_dev_liana_ime_LianaJni_nativeNew(JNIEnv *env, jclass cls, jstring mode) {
    (void)cls;
    char *m = to_chars(env, mode);
    LianaSession *s = liana_new(m);
    free(m);
    return (jlong)(intptr_t)s;
}

JNIEXPORT jlong JNICALL
Java_dev_liana_ime_LianaJni_nativeNewWithDict(JNIEnv *env, jclass cls,
                                              jstring mode, jstring dict_path) {
    (void)cls;
    char *m = to_chars(env, mode);
    char *p = to_chars(env, dict_path);
    LianaSession *s = liana_new_with_dict(m, p);
    free(m);
    free(p);
    return (jlong)(intptr_t)s;
}

JNIEXPORT void JNICALL
Java_dev_liana_ime_LianaJni_nativeFree(JNIEnv *env, jclass cls, jlong session) {
    (void)env; (void)cls;
    liana_free(SESSION);
}

JNIEXPORT jint JNICALL
Java_dev_liana_ime_LianaJni_nativeFeed(JNIEnv *env, jclass cls,
                                       jlong session, jstring ch) {
    (void)cls;
    char *c = to_chars(env, ch);
    jint r = c ? liana_feed(SESSION, c) : 0;
    free(c);
    return r;
}

JNIEXPORT jint JNICALL
Java_dev_liana_ime_LianaJni_nativeBackspace(JNIEnv *env, jclass cls, jlong session) {
    (void)env; (void)cls;
    return liana_backspace(SESSION);
}

JNIEXPORT void JNICALL
Java_dev_liana_ime_LianaJni_nativeClear(JNIEnv *env, jclass cls, jlong session) {
    (void)env; (void)cls;
    liana_clear(SESSION);
}

JNIEXPORT jint JNICALL
Java_dev_liana_ime_LianaJni_nativeSetMode(JNIEnv *env, jclass cls,
                                          jlong session, jstring mode) {
    (void)cls;
    char *m = to_chars(env, mode);
    jint r = m ? liana_set_mode(SESSION, m) : 0;
    free(m);
    return r;
}

JNIEXPORT jstring JNICALL
Java_dev_liana_ime_LianaJni_nativeMode(JNIEnv *env, jclass cls, jlong session) {
    (void)cls;
    return to_jstring(env, liana_mode(SESSION));
}

/* 内置语言清单（JSON）：菜单的唯一来源，Kotlin 侧不再写死 pinyin/en。 */
JNIEXPORT jstring JNICALL
Java_dev_liana_ime_LianaJni_nativeLanguages(JNIEnv *env, jclass cls) {
    (void)cls;
    return to_jstring(env, liana_languages());
}

JNIEXPORT jint JNICALL
Java_dev_liana_ime_LianaJni_nativeSetTraditional(JNIEnv *env, jclass cls,
                                                 jlong session, jint on) {
    (void)env; (void)cls;
    return liana_set_traditional(SESSION, on);
}

JNIEXPORT jint JNICALL
Java_dev_liana_ime_LianaJni_nativeTraditional(JNIEnv *env, jclass cls, jlong session) {
    (void)env; (void)cls;
    return liana_traditional(SESSION);
}

JNIEXPORT jstring JNICALL
Java_dev_liana_ime_LianaJni_nativeCompositionJson(JNIEnv *env, jclass cls, jlong session) {
    (void)cls;
    return to_jstring(env, liana_composition_json(SESSION));
}

JNIEXPORT jstring JNICALL
Java_dev_liana_ime_LianaJni_nativeSelect(JNIEnv *env, jclass cls,
                                         jlong session, jint index) {
    (void)cls;
    return to_jstring(env, liana_select(SESSION, (uint32_t)index));
}

JNIEXPORT jstring JNICALL
Java_dev_liana_ime_LianaJni_nativeCommitRaw(JNIEnv *env, jclass cls, jlong session) {
    (void)cls;
    return to_jstring(env, liana_commit_raw(SESSION));
}

JNIEXPORT jint JNICALL
Java_dev_liana_ime_LianaJni_nativeRecordCommit(JNIEnv *env, jclass cls,
                                               jlong session, jstring text) {
    (void)cls;
    char *t = to_chars(env, text);
    jint r = t ? liana_record_commit(SESSION, t) : -1;
    free(t);
    return r;
}

JNIEXPORT jstring JNICALL
Java_dev_liana_ime_LianaJni_nativeUserExport(JNIEnv *env, jclass cls, jlong session) {
    (void)cls;
    return to_jstring(env, liana_user_export(SESSION));
}

JNIEXPORT jint JNICALL
Java_dev_liana_ime_LianaJni_nativeUserImport(JNIEnv *env, jclass cls,
                                             jlong session, jstring tsv) {
    (void)cls;
    char *t = to_chars(env, tsv);
    jint r = t ? liana_user_import(SESSION, t) : -1;
    free(t);
    return r;
}

JNIEXPORT jstring JNICALL
Java_dev_liana_ime_LianaJni_nativeVersion(JNIEnv *env, jclass cls) {
    (void)cls;
    return (*env)->NewStringUTF(env, liana_version());
}