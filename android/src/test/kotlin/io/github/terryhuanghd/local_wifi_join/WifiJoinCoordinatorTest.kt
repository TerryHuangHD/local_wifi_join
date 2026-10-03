package io.github.terryhuanghd.local_wifi_join

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/*
 * Run with `./gradlew :local_wifi_join:testDebugUnitTest` from `example/android`
 * after `flutter build apk --config-only` in `example`.
 */
internal class WifiJoinCoordinatorTest {
    private class FakeRequest(
        val ssid: String,
        val listener: NetworkRequestListener<String>,
        val boundAtRequest: String?,
    ) {
        var released = false
    }

    private class FakeTimer(val dueAt: Long, val action: () -> Unit) {
        var cancelled = false
    }

    private class FakePlatform : WifiNetworkPlatform<String> {
        val requests = mutableListOf<FakeRequest>()
        val timers = mutableListOf<FakeTimer>()
        var boundNetwork: String? = null
        var bindSucceeds = true
        var requestFailure: RuntimeException? = null
        private var now = 0L

        override fun requestNetwork(
            ssid: String,
            passphrase: String,
            listener: NetworkRequestListener<String>,
        ): Cancellable {
            requestFailure?.let { throw it }
            val request = FakeRequest(ssid, listener, boundNetwork)
            requests += request
            return Cancellable { request.released = true }
        }

        override fun bindProcessToNetwork(network: String): Boolean {
            if (bindSucceeds) boundNetwork = network
            return bindSucceeds
        }

        override fun unbindProcessFrom(network: String) {
            if (boundNetwork == network) boundNetwork = null
        }

        override fun schedule(delayMillis: Long, action: () -> Unit): Cancellable {
            val timer = FakeTimer(now + delayMillis, action)
            timers += timer
            return Cancellable { timer.cancelled = true }
        }

        fun advanceBy(millis: Long) {
            now += millis
            timers.filter { !it.cancelled && it.dueAt <= now }.forEach {
                it.cancelled = true
                it.action()
            }
        }

        val activeRequests get() = requests.filter { !it.released }
    }

    private val platform = FakePlatform()
    private val coordinator = WifiJoinCoordinator(platform)

    private fun join(ssid: String = "DEVICE-AP", timeoutMillis: Long = 30_000): List<JoinOutcome> {
        val replies = mutableListOf<JoinOutcome>()
        coordinator.join(ssid, "12345678", timeoutMillis) { replies += it }
        return replies
    }

    @Test
    fun available_bindsProcessAndKeepsRequestRegistered() {
        val replies = join()

        platform.requests.single().listener.onAvailable("net1")

        assertEquals(listOf(JoinOutcome.JOINED), replies)
        assertEquals("net1", platform.boundNetwork)
        assertEquals(1, platform.activeRequests.size)
    }

    @Test
    fun unavailable_repliesUnavailableAndReleasesRequest() {
        val replies = join()

        platform.requests.single().listener.onUnavailable()

        assertEquals(listOf(JoinOutcome.UNAVAILABLE), replies)
        assertTrue(platform.activeRequests.isEmpty())
        assertNull(platform.boundNetwork)
    }

    @Test
    fun timeout_releasesRequestAndIgnoresLateAvailability() {
        val replies = join(timeoutMillis = 1_000)

        platform.advanceBy(999)
        assertTrue(replies.isEmpty())
        platform.advanceBy(1)
        platform.requests.single().listener.onAvailable("net1")

        assertEquals(listOf(JoinOutcome.TIMEOUT), replies)
        assertTrue(platform.activeRequests.isEmpty())
        assertNull(platform.boundNetwork, "a timed-out request must never bind the process")
    }

    @Test
    fun timeout_doesNotAffectAnEstablishedJoin() {
        val replies = join(timeoutMillis = 1_000)
        platform.requests.single().listener.onAvailable("net1")

        platform.advanceBy(5_000)

        assertEquals(listOf(JoinOutcome.JOINED), replies)
        assertEquals("net1", platform.boundNetwork)
        assertEquals(1, platform.activeRequests.size)
    }

    @Test
    fun secondJoin_cancelsPendingJoinAfterReleasingIt() {
        val first = mutableListOf<JoinOutcome>()
        var firstReleasedAtReply: Boolean? = null
        coordinator.join("DEVICE-AP", "12345678", 30_000) {
            first += it
            firstReleasedAtReply = platform.requests[0].released
        }

        val second = join()
        platform.requests[0].listener.onAvailable("stale")
        platform.requests[1].listener.onAvailable("net2")

        assertEquals(listOf(JoinOutcome.CANCELLED), first)
        assertEquals(true, firstReleasedAtReply, "teardown must happen before the reply")
        assertEquals(listOf(JoinOutcome.JOINED), second)
        assertEquals("net2", platform.boundNetwork)
        assertEquals(listOf(platform.requests[1]), platform.activeRequests)
    }

    @Test
    fun secondJoin_releasesEstablishedJoinBeforeRequestingAgain() {
        val first = join()
        platform.requests.single().listener.onAvailable("net1")

        join(ssid = "OTHER-AP")

        assertEquals(listOf(JoinOutcome.JOINED), first)
        assertNull(platform.requests[1].boundAtRequest, "old binding must be cleared before requesting")
        assertTrue(platform.requests[0].released)
        assertEquals("OTHER-AP", platform.activeRequests.single().ssid)
    }

    @Test
    fun leave_isIdempotentWithoutJoin() {
        coordinator.leave()
        coordinator.leave()

        assertTrue(platform.requests.isEmpty())
        assertNull(platform.boundNetwork)
    }

    @Test
    fun leave_cancelsPendingJoin() {
        val replies = join()

        coordinator.leave()
        platform.requests.single().listener.onAvailable("net1")

        assertEquals(listOf(JoinOutcome.CANCELLED), replies)
        assertTrue(platform.activeRequests.isEmpty())
        assertNull(platform.boundNetwork)
    }

    @Test
    fun leave_releasesEstablishedJoin() {
        val replies = join()
        platform.requests.single().listener.onAvailable("net1")

        coordinator.leave()
        coordinator.leave()

        assertEquals(listOf(JoinOutcome.JOINED), replies)
        assertTrue(platform.activeRequests.isEmpty())
        assertNull(platform.boundNetwork)
    }

    @Test
    fun lost_unbindsAndReleasesTheRequest() {
        join()
        val listener = platform.requests.single().listener
        listener.onAvailable("net1")

        listener.onLost("net1")

        assertNull(platform.boundNetwork)
        assertTrue(platform.activeRequests.isEmpty())
    }

    @Test
    fun lost_ignoresOtherNetworks() {
        join()
        val listener = platform.requests.single().listener
        listener.onAvailable("net1")

        listener.onLost("net0")

        assertEquals("net1", platform.boundNetwork)
        assertEquals(1, platform.activeRequests.size)
    }

    @Test
    fun rejectedParameters_replyInvalidArgumentsAndLeaveNoState() {
        platform.requestFailure = IllegalArgumentException("passphrase not ASCII encodable")

        val replies = join()

        assertEquals(listOf(JoinOutcome.invalidArguments("passphrase not ASCII encodable")), replies)
        assertTrue(platform.timers.isEmpty())

        platform.requestFailure = null
        val retry = join()
        platform.requests.single().listener.onAvailable("net1")
        assertEquals(listOf(JoinOutcome.JOINED), retry)
    }

    @Test
    fun requestFailure_repliesFailedWithExceptionName() {
        platform.requestFailure = SecurityException("missing CHANGE_NETWORK_STATE")

        val replies = join()

        assertEquals(listOf(JoinOutcome.failed("SecurityException", "missing CHANGE_NETWORK_STATE")), replies)
    }

    @Test
    fun bindFailure_repliesFailedAndReleasesRequest() {
        platform.bindSucceeds = false
        val replies = join()

        platform.requests.single().listener.onAvailable("net1")

        assertEquals("failed", replies.single().status)
        assertEquals("bindProcessToNetworkFailed", replies.single().platformCode)
        assertTrue(platform.activeRequests.isEmpty())
        assertFalse(platform.timers.any { !it.cancelled })
    }

    @Test
    fun dispose_cancelsPendingJoin() {
        val replies = join()

        coordinator.dispose()

        assertEquals(listOf(JoinOutcome.CANCELLED), replies)
        assertTrue(platform.activeRequests.isEmpty())
    }
}
