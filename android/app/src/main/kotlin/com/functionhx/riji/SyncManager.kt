package com.functionhx.riji

import android.content.Context
import com.functionhx.riji.core.Base64Url
import com.functionhx.riji.core.JsonValue
import com.functionhx.riji.core.Pairing
import com.functionhx.riji.core.Segment
import com.functionhx.riji.core.SegmentHead
import com.functionhx.riji.core.SyncKey
import com.functionhx.riji.core.SyncTransport
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** 腾讯云 riji-sync 的 HTTP 访问（server/sync），阻塞调用，在 IO 线程上用。连接码与邮件提醒共用。 */
class HttpSyncTransport(private val token: String?) : SyncTransport {
    class Failure(val status: Int, val code: String?) : Exception(
        when {
            status == 401 -> "连接码不对"
            code == "not_found" -> "配对码不存在或已过期"
            code == "taken" -> "这个配对码已经被另一台设备用了"
            status == 429 -> "试得太频繁了，过几分钟再来"
            status == 0 -> "连不上同步服务"
            else -> "同步服务返回 $status${code?.let { "（$it）" } ?: ""}"
        },
    )

    fun request(method: String, path: String, query: String = "", body: JSONObject? = null): Pair<Int, JSONObject> {
        val connection = (URL(ENDPOINT + path + if (query.isEmpty()) "" else "?$query").openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 15_000
            readTimeout = 30_000
            token?.let { setRequestProperty("Authorization", "Bearer $it") }
            if (body != null) { doOutput = true; setRequestProperty("Content-Type", "application/json") }
        }
        body?.let { json -> connection.outputStream.use { it.write(json.toString().toByteArray()) } }
        val code = connection.responseCode
        val text = (if (code in 200..299) connection.inputStream else connection.errorStream)?.bufferedReader()?.use { it.readText() } ?: "{}"
        return code to (runCatching { JSONObject(text) }.getOrDefault(JSONObject()))
    }

    private fun ok(result: Pair<Int, JSONObject>): JSONObject =
        if (result.first == 200) result.second else throw Failure(result.first, result.second.optString("error").ifEmpty { null })

    override fun heads(): Map<String, SegmentHead> {
        val devices = ok(request("GET", "heads")).optJSONObject("devices") ?: return emptyMap()
        return devices.keys().asSequence().associateWith { device ->
            devices.getJSONObject(device).let { SegmentHead(it.getInt("seq"), it.getString("hash")) }
        }
    }

    override fun fetch(device: String, from: Int, limit: Int): List<Segment> {
        val list = ok(request("GET", "segments", "device=${URLEncoder.encode(device, "UTF-8")}&from=$from&limit=$limit")).optJSONArray("segments") ?: return emptyList()
        return (0 until list.length()).map { Segment.from(JsonValue.parse(list.getJSONObject(it).toString())) }
    }

    override fun push(segments: List<Segment>) {
        val array = JSONArray(segments.map { JSONObject(String(it.json().canonicalBytes())) })
        ok(request("POST", "segments", body = JSONObject().put("segments", array)))
    }

    companion object { const val ENDPOINT = "https://fanyuchen.com.cn/riji/sync/" }
}

/** 日迹密钥存在应用私有目录（系统文件级加密保护）。 */
object SyncKeyStore {
    private fun file(context: Context) = File(context.filesDir, "riji/sync-key.json")
    fun load(context: Context): SyncKey? = file(context).takeIf { it.exists() }?.let { runCatching { SyncKey.from(JsonValue.parse(it.readText())) }.getOrNull() }
    fun save(context: Context, key: SyncKey) {
        val target = file(context)
        target.parentFile?.mkdirs()
        target.writeBytes(key.json().canonicalBytes())
    }
}

/** 加入配对（这台手机是加入端）：输入 Mac 上的配对码 → 两边显示比对码 → 等 Mac 确认后取回信封。 */
class PairingJoin(private val code: String) {
    private val own = Pairing.generate()
    private val transport = HttpSyncTransport(null)
    private var pairKey: ByteArray? = null

    /** → 6 位比对码（阻塞）。 */
    fun join(): String {
        val result = transport.request("POST", "pair/join", body = JSONObject().put("code", code).put("pub", own.publicKey))
        if (result.first != 200) throw HttpSyncTransport.Failure(result.first, result.second.optString("error").ifEmpty { null })
        val initiator = result.second.getString("pub")
        val (key, sas) = Pairing.keys(Pairing.shared(own, initiator), Pairing.transcript(code, initiator, own.publicKey))
        pairKey = key
        return sas
    }

    /** 轮询信封；Mac 还没确认时返回 null。 */
    fun fetch(): JsonValue? {
        val result = transport.request("POST", "pair/fetch", body = JSONObject().put("code", code).put("pub", own.publicKey))
        return when (result.first) {
            202 -> null
            200 -> Pairing.open(pairKey!!, code, result.second.getString("sealed"))
            else -> throw HttpSyncTransport.Failure(result.first, result.second.optString("error").ifEmpty { null })
        }
    }

    companion object {
        fun keyFrom(payload: JsonValue): SyncKey? {
            val key = payload["key"]?.string?.let { runCatching { Base64Url.decode(it) }.getOrNull() }?.takeIf { it.size == 32 } ?: return null
            return SyncKey(key, payload["epoch"]?.int ?: 0)
        }
    }
}
