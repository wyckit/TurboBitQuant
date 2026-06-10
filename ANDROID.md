# TurboBitQuant Android APK

This Android app runs GGUF models on the phone through the official `llama.cpp` Android JNI binding. It does not require the desktop Flask host or a LAN connection.

## Practical Model Size

Start with a small Q4 GGUF model. The local files currently in `models/` are about 3.12 GB and 4.8 GB, which require a high-memory phone and may still be slow or fail to load. A 2B-class Q4 model with a 4096 context is the safest first target.

## Build Prerequisites

Install:

- Android Studio
- Android SDK Platform, Platform-Tools, Build-Tools, Command-line Tools
- Android NDK side-by-side version `29.0.13113456`
- Java 17 or newer

Set these environment variables:

```powershell
[System.Environment]::SetEnvironmentVariable("JAVA_HOME", "C:\Program Files\Android\Android Studio\jbr", "User")
[System.Environment]::SetEnvironmentVariable("ANDROID_HOME", "$env:LocalAppData\Android\Sdk", "User")
$VERSION = Get-ChildItem -Name "$env:LocalAppData\Android\Sdk\ndk" | Select-Object -Last 1
[System.Environment]::SetEnvironmentVariable("NDK_HOME", "$env:LocalAppData\Android\Sdk\ndk\$VERSION", "User")
```

Restart PowerShell after setting the variables.

## Build

```powershell
.\build-android-apk.ps1 -Configuration Debug
```

The debug APK will be written to:

```text
android\app\build\outputs\apk\debug\app-debug.apk
```

## Run A Model

Install the APK on the phone and launch TurboBitQuant.

You can load a model in two ways:

- Tap **Pick GGUF from phone storage** and select a `.gguf` file already on the phone.
- Search the **Hugging Face Model Hub** inside the app, pick a repository, download a `.gguf`, then tap **Load**.

Downloaded models are saved in the app's private `models` directory. The app shows download progress, lets you cancel active downloads, prevents duplicate downloads, and provides **Load** and **Delete** actions for downloaded models.

To build a self-contained APK with a bundled model, place a small model here before building:

```text
android\app\src\main\assets\models\default.gguf
```

Bundling multi-GB models can make APK creation, installation, and phone storage unreliable, so the file-picker path is usually better.
