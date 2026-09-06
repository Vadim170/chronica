# Keep the UniFFI-generated bindings and JNA structures; they are accessed
# reflectively / via native code and must not be stripped or renamed.
-keep class uniffi.** { *; }
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { *; }
-dontwarn java.awt.**
