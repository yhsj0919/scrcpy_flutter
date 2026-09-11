package dev.scrcpy.flutter.transport

import java.io.File

/** ADB operations bound to exactly one physical target. */
internal interface AdbDeviceTransport {
    fun shell(command: String): String
    fun shellResult(command: String): AndroidAdbTransport.ShellResult
    fun push(localFile: File, remotePath: String)
    fun pull(remotePath: String, localFile: File)
    fun open(service: String): AdbSocketStream
}
