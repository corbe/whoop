# Phase 9 — release build (R8). O SDK de chat (juggle_im) usa okhttp, que
# referencia providers TLS opcionais (OpenJSSE/Conscrypt/BouncyCastle) via
# reflection. R8 nao encontra as classes no classpath → falha o build.
-dontwarn org.openjsse.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.apache.harmony.**
