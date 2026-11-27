package org.localsend.localsend_app

import fi.iki.elonen.NanoHTTPD
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * Minimal HTTP API for the TV keyboard (:53318, plain HTTP, LAN only).
 *
 * - GET  /kb          -> single-page keyboard (assets/kb.html)
 * - GET  /kb/state    -> editor/connection state for the client
 * - GET  /kb/snapshot -> extracted text and selection snapshot
 * - POST /kb/text     -> {op:"ins"|"del"|"sel"|"relmove"|"replace"|"key", ...}
 * - POST /kb/action   -> {action:"enter"|"tab"|"selectAll"|"cut"|"copy"|"paste"|"deleteWord"|"home"|"end"}
 * - GET/POST /kb/clipboard -> TV clipboard read/write
 *
 * Auth: if the receive PIN is configured, requests must pass `pin` (query param),
 * unless the source IP was just observed through LocalSend's authenticated
 * `/register` event.
 * Writes are rate limited per client IP.
 */
class KeyboardHttpServer(
    private val ime: LocalSendImeService,
    port: Int
) : NanoHTTPD("0.0.0.0", port) {

    companion object {
        private const val RATE_LIMIT_PER_SECOND = 60
        private const val CLIENT_TTL_MS = 60_000L
        private const val MAX_TEXT_LENGTH = 100_000
    }

    private val clients = ConcurrentHashMap<String, Long>()
    private val trustedClients = ConcurrentHashMap<String, Long>()

    fun trustClient(ip: String) {
        trustedClients[ip] = System.currentTimeMillis() + CLIENT_TTL_MS
    }

    private val writeTimestamps = ConcurrentHashMap<String, ArrayDeque<Long>>()

    override fun serve(session: IHTTPSession): Response {
        val ip = session.remoteIpAddress ?: "unknown"
        touchClient(ip)

        val path = session.uri
        return try {
            when {
                path == "/kb" || path == "/kb/" -> serveKeyboardPage()
                path == "/kb/state" -> {
                    if (!checkRateLimit(ip)) return rateLimited()
                    if (!checkPin(session)) return unauthorized()
                    serveState(ip)
                }
                path == "/kb/snapshot" -> {
                    if (!checkRateLimit(ip)) return rateLimited()
                    if (!checkPin(session)) return unauthorized()
                    serveSnapshot()
                }
                path == "/kb/clipboard" -> {
                    if (!checkRateLimit(ip)) return rateLimited()
                    if (!checkPin(session)) return unauthorized()
                    serveClipboard(session)
                }
                path == "/kb/text" -> {
                    if (!checkRateLimit(ip)) return rateLimited()
                    if (!checkPin(session)) return unauthorized()
                    serveText(session)
                }
                path == "/kb/action" -> {
                    if (!checkRateLimit(ip)) return rateLimited()
                    if (!checkPin(session)) return unauthorized()
                    serveAction(session)
                }
                else -> json(Response.Status.NOT_FOUND, JSONObject().put("ok", false).put("error", "not_found"))
            }
        } catch (e: Exception) {
            json(
                Response.Status.BAD_REQUEST,
                JSONObject().put("ok", false).put("error", e.message ?: "error")
            )
        }
    }

    // region handlers

    private fun serveKeyboardPage(): Response {
        val html = ime.assets.open("kb.html").use { it.readBytes() }
        return newFixedLengthResponse(Response.Status.OK, "text/html; charset=utf-8", String(html, Charsets.UTF_8))
    }

    private fun serveState(ip: String): Response {
        if (!ime.isKeyboardEnabled()) {
            return json(Response.Status.OK, JSONObject().put("ok", false).put("reason", "disabled"))
        }
        ime.markKeyboardClient(ip)
        val body = JSONObject()
            .put("ok", true)
            .put("visible", ime.editorVisible)
            .put("password", ime.isPasswordEditor)
            .put("clients", clientCount())
        return json(Response.Status.OK, body)
    }

    private fun serveSnapshot(): Response {
        val snapshot = ime.readSnapshot()
            ?: return json(Response.Status.OK, JSONObject().put("ok", false).put("error", "snapshot_unavailable"))
        val body = JSONObject().put("ok", true)
        snapshot.forEach { (key, value) -> body.put(key, value) }
        return json(Response.Status.OK, body)
    }

    private fun serveClipboard(session: IHTTPSession): Response {
        return when (session.method) {
            Method.GET -> json(
                Response.Status.OK,
                JSONObject().put("ok", true).put("text", ime.readClipboard())
            )
            Method.POST -> {
                val payload = readJsonBody(session) ?: return badRequest("invalid json")
                val text = payload.optString("text")
                if (text.length > MAX_TEXT_LENGTH) return badRequest("invalid text")
                json(Response.Status.OK, JSONObject().put("ok", ime.writeClipboard(text)))
            }
            else -> json(
                Response.Status.lookup(405) ?: Response.Status.BAD_REQUEST,
                JSONObject().put("ok", false).put("error", "method_not_allowed"),
            )
        }
    }

    private fun serveText(session: IHTTPSession): Response {
        val payload = readJsonBody(session) ?: return badRequest("invalid json")
        val op = payload.optString("op")
        val applied = when (op) {
            "ins" -> {
                val text = payload.optString("text")
                if (text.isEmpty() || text.length > MAX_TEXT_LENGTH) {
                    return badRequest("invalid text")
                }
                ime.applyInsert(text)
            }
            "del" -> ime.applyDelete(payload.optInt("before", 1), payload.optInt("after", 0))
            "sel" -> ime.applySelection(payload.optInt("a", 0), payload.optInt("b", 0))
            "relmove" -> ime.applyRelativeCursorMove(payload.optInt("dx", 0))
            "replace" -> {
                val text = payload.optString("text")
                if (text.length > MAX_TEXT_LENGTH) {
                    return badRequest("invalid text")
                }
                ime.applyReplaceAll(text)
            }
            "key" -> when (payload.optString("code")) {
                "enter" -> ime.applyEnter()
                "tab" -> ime.applyTab()
                "deleteWord" -> ime.applyDeleteWord()
                "home" -> ime.applyMoveToLineBoundary(false)
                "end" -> ime.applyMoveToLineBoundary(true)
                else -> return badRequest("unknown key")
            }
            else -> return badRequest("unknown op")
        }
        return json(
            Response.Status.OK,
            JSONObject().put("ok", true).put("applied", applied)
        )
    }

    private fun serveAction(session: IHTTPSession): Response {
        val payload = readJsonBody(session) ?: return badRequest("invalid json")
        val action = payload.optString("action")
        val applied = when (action) {
            "enter" -> ime.applyEnter()
            "tab" -> ime.applyTab()
            "deleteWord" -> ime.applyDeleteWord()
            "home" -> ime.applyMoveToLineBoundary(false)
            "end" -> ime.applyMoveToLineBoundary(true)
            "selectAll", "cut", "copy", "paste" -> ime.applyContextMenuAction(action)
            else -> return badRequest("unknown action")
        }
        return json(
            Response.Status.OK,
            JSONObject().put("ok", true).put("applied", applied)
        )
    }

    // endregion

    // region helpers

    private fun readJsonBody(session: IHTTPSession): JSONObject? {
        // NanoHTTPD defaults a body without an explicit charset to US-ASCII.
        // JSON sent by browsers is UTF-8 even when the browser omits charset,
        // so normalize the header before NanoHTTPD decodes postData.
        val headers = session.headers
        val contentType = headers["content-type"]
        if (contentType != null &&
            contentType.substringBefore(';').trim().equals("application/json", ignoreCase = true) &&
            !contentType.contains("charset=", ignoreCase = true)
        ) {
            headers["content-type"] = "$contentType; charset=UTF-8"
        }

        val map = HashMap<String, String>()
        session.parseBody(map)
        val raw = map["postData"] ?: return null
        return JSONObject(raw)
    }

    private fun checkPin(session: IHTTPSession): Boolean {
        val pin = ime.readPin() ?: return true // no PIN configured
        val now = System.currentTimeMillis()
        val clientIp = session.remoteIpAddress ?: return false
        val trustedUntil = trustedClients[clientIp]
        if (trustedUntil != null && trustedUntil > now) return true
        if (trustedUntil != null) trustedClients.remove(clientIp)
        val provided = session.parms["pin"] ?: return false
        return provided == pin
    }

    private fun checkRateLimit(ip: String): Boolean {
        val now = System.currentTimeMillis()
        var window = writeTimestamps[ip]
        if (window == null) {
            window = ArrayDeque()
            writeTimestamps[ip] = window
        }
        synchronized(window) {
            while (window.isNotEmpty() && now - window.first() > 1000L) {
                window.removeFirst()
            }
            if (window.size >= RATE_LIMIT_PER_SECOND) {
                return false
            }
            window.addLast(now)
            return true
        }
    }

    private fun touchClient(ip: String) {
        val now = System.currentTimeMillis()
        val it = clients.keys.iterator()
        while (it.hasNext()) {
            val key = it.next()
            val seen = clients[key] ?: continue
            if (now - seen > CLIENT_TTL_MS) {
                it.remove()
            }
        }
        val trustedIt = trustedClients.entries.iterator()
        while (trustedIt.hasNext()) {
            if (trustedIt.next().value <= now) trustedIt.remove()
        }
        clients[ip] = now
    }

    private fun clientCount(): Int {
        val now = System.currentTimeMillis()
        return clients.count { now - it.value <= CLIENT_TTL_MS }
    }

    private fun json(status: Response.Status, body: JSONObject): Response =
        newFixedLengthResponse(status, "application/json; charset=utf-8", body.toString())

    private fun badRequest(message: String): Response =
        json(Response.Status.BAD_REQUEST, JSONObject().put("ok", false).put("error", message))

    private fun unauthorized(): Response =
        json(Response.Status.UNAUTHORIZED, JSONObject().put("ok", false).put("error", "pin_required"))

    private fun rateLimited(): Response {
        val status = Response.Status.lookup(429) ?: Response.Status.BAD_REQUEST
        return json(status, JSONObject().put("ok", false).put("error", "rate_limited"))
    }

    // endregion
}
