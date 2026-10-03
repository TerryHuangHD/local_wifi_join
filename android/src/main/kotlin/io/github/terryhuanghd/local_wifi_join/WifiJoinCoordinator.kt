package io.github.terryhuanghd.local_wifi_join

/** The reply sent to Dart for one `join` call. */
internal data class JoinOutcome(
    val status: String,
    val platformCode: String? = null,
    val message: String? = null,
) {
    fun toMap(): Map<String, Any?> =
        mapOf("status" to status, "platformCode" to platformCode, "message" to message)

    companion object {
        val JOINED = JoinOutcome("joined")
        val UNAVAILABLE = JoinOutcome("unavailable")
        val TIMEOUT = JoinOutcome("timeout")
        val CANCELLED = JoinOutcome("cancelled")

        fun invalidArguments(message: String?) = JoinOutcome("invalidArguments", message = message)

        fun failed(platformCode: String?, message: String?) = JoinOutcome("failed", platformCode, message)
    }
}

/** Handle that undoes a registration or a scheduled action. Calling it twice is harmless. */
internal fun interface Cancellable {
    fun cancel()
}

/** Network request events, delivered on the main thread. */
internal interface NetworkRequestListener<N> {
    fun onAvailable(network: N)

    fun onUnavailable()

    fun onLost(network: N)
}

/** Platform operations used by [WifiJoinCoordinator]. Every method is called on the main thread. */
internal interface WifiNetworkPlatform<N> {
    /**
     * Requests the WPA2-Personal network [ssid]. Events go to [listener] until the returned
     * handle is cancelled. Throws [IllegalArgumentException] for parameters the platform rejects.
     */
    fun requestNetwork(ssid: String, passphrase: String, listener: NetworkRequestListener<N>): Cancellable

    /** Routes all of the process's traffic through [network]. Returns false on failure. */
    fun bindProcessToNetwork(network: N): Boolean

    /** Restores the default network, but only if the process is still bound to [network]. */
    fun unbindProcessFrom(network: N)

    /** Runs [action] on the main thread after [delayMillis] unless cancelled first. */
    fun schedule(delayMillis: Long, action: () -> Unit): Cancellable
}

/**
 * Main-thread state machine behind `join` and `leave`.
 *
 * Invariants:
 * - Every `join` reply is delivered exactly once.
 * - At most one network request is registered at a time; a new `join` tears down the previous one.
 * - Events from a request that is no longer current are ignored, so a timed-out or cancelled
 *   request can never bind the process later.
 * - Teardown happens before the reply, so Dart never observes a half-released state.
 */
internal class WifiJoinCoordinator<N : Any>(private val platform: WifiNetworkPlatform<N>) {
    private class Session<N>(var reply: ((JoinOutcome) -> Unit)?) {
        var request: Cancellable? = null
        var timeout: Cancellable? = null
        var network: N? = null
    }

    private var current: Session<N>? = null

    fun join(ssid: String, passphrase: String, timeoutMillis: Long, reply: (JoinOutcome) -> Unit) {
        endSession(JoinOutcome.CANCELLED)

        val session = Session<N>(reply)
        current = session
        val listener = object : NetworkRequestListener<N> {
            override fun onAvailable(network: N) {
                if (current === session) onAvailable(session, network)
            }

            override fun onUnavailable() {
                if (current === session) endSession(JoinOutcome.UNAVAILABLE)
            }

            override fun onLost(network: N) {
                if (current === session && session.network == network) {
                    endSession(JoinOutcome.failed("networkLost", "The network was lost"))
                }
            }
        }

        val request = try {
            platform.requestNetwork(ssid, passphrase, listener)
        } catch (e: IllegalArgumentException) {
            endSession(JoinOutcome.invalidArguments(e.message))
            return
        } catch (e: RuntimeException) {
            // SecurityException, ConnectivityManager.TooManyRequestsException, ...
            endSession(JoinOutcome.failed(e.javaClass.simpleName, e.message))
            return
        }
        if (current !== session) {
            // Ended synchronously from inside requestNetwork.
            request.cancel()
            return
        }
        session.request = request
        session.timeout = platform.schedule(timeoutMillis) {
            if (current === session && session.reply != null) endSession(JoinOutcome.TIMEOUT)
        }
    }

    /** Ends the current join, pending or established. Idempotent. */
    fun leave() = endSession(JoinOutcome.CANCELLED)

    /** Releases everything when the engine goes away. */
    fun dispose() = endSession(JoinOutcome.CANCELLED)

    private fun onAvailable(session: Session<N>, network: N) {
        if (!platform.bindProcessToNetwork(network)) {
            endSession(
                JoinOutcome.failed(
                    "bindProcessToNetworkFailed",
                    "ConnectivityManager.bindProcessToNetwork returned false",
                ),
            )
            return
        }
        session.network = network
        complete(session, JoinOutcome.JOINED)
    }

    private fun complete(session: Session<N>, outcome: JoinOutcome) {
        val reply = session.reply ?: return
        session.reply = null
        session.timeout?.cancel()
        reply(outcome)
    }

    /** Tears down the current session; replies [outcomeIfPending] if it had not replied yet. */
    private fun endSession(outcomeIfPending: JoinOutcome) {
        val session = current ?: return
        current = null
        session.timeout?.cancel()
        session.request?.cancel()
        session.network?.let(platform::unbindProcessFrom)
        complete(session, outcomeIfPending)
    }
}
