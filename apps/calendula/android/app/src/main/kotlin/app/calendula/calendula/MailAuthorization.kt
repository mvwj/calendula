package app.calendula.calendula

import android.app.Activity
import android.content.Context
import android.accounts.Account
import android.content.Intent
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import io.flutter.plugin.common.MethodChannel

/** Official Google authorization UI. Only Gmail read permission, no server code. */
class MailAuthorization(private val activity: Activity) {
    companion object {
        /** Uses only an already granted account. A headless check cannot open
         * account selection or a consent UI and never logs an access token. */
        fun renewReadPermission(context: Context, email: String?, result: MethodChannel.Result) {
            if (email.isNullOrBlank()) { result.error("MAIL_LOGIN", "Reconnect Gmail to select an account.", null); return }
            val request = AuthorizationRequest.builder()
                .setRequestedScopes(listOf(Scope("https://www.googleapis.com/auth/gmail.readonly")))
                .setAccount(Account(email, "com.google")).build()
            Identity.getAuthorizationClient(context).authorize(request)
                .addOnSuccessListener { authorization ->
                    if (authorization.hasResolution() || authorization.accessToken.isNullOrBlank())
                        result.error("MAIL_LOGIN", "Reconnect Gmail to renew permission.", null)
                    else result.success(authorization.accessToken)
                }
                .addOnFailureListener { result.error("MAIL_LOGIN", "Read permission unavailable.", null) }
        }
    }
    private var pending: MethodChannel.Result? = null
    private val requestCode = 6230
    fun authorize(interactive: Boolean, email: String?, chooseAccount: Boolean, result: MethodChannel.Result) {
        if (pending != null) { result.error("MAIL_BUSY", "Authorization is already open.", null); return }
        pending = result
        val builder = AuthorizationRequest.builder()
            .setRequestedScopes(listOf(Scope("https://www.googleapis.com/auth/gmail.readonly")))
        if (!email.isNullOrBlank()) builder.setAccount(Account(email, "com.google"))
        if (interactive && chooseAccount) builder.setPrompt(AuthorizationRequest.Prompt.SELECT_ACCOUNT)
        val request = builder.build()
        Identity.getAuthorizationClient(activity).authorize(request)
            .addOnSuccessListener { authorization ->
                if (authorization.hasResolution()) {
                    if (!interactive) { finishError("MAIL_LOGIN", "Reconnect Gmail to renew permission."); return@addOnSuccessListener }
                    try { activity.startIntentSenderForResult(authorization.pendingIntent!!.intentSender, requestCode, null, 0, 0, 0) }
                    catch (_: Exception) { finishError("MAIL_LOGIN", "Google authorization could not open.") }
                } else finishToken(authorization.accessToken)
            }
            .addOnFailureListener { finishError("MAIL_LOGIN", "Gmail authorization failed. Check the Android OAuth client and signing fingerprint in your Google project.") }
    }
    fun activityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        if (resultCode != Activity.RESULT_OK) { finishError("MAIL_CANCELLED", "Gmail connection was cancelled."); return true }
        try { finishToken(Identity.getAuthorizationClient(activity).getAuthorizationResultFromIntent(data).accessToken) }
        catch (_: Exception) { finishError("MAIL_LOGIN", "Gmail permission could not be obtained.") }
        return true
    }
    private fun finishToken(token: String?) {
        val result = pending ?: return
        pending = null
        if (token.isNullOrEmpty()) result.error("MAIL_LOGIN", "Google did not return read access.", null)
        else result.success(token)
    }
    private fun finishError(code: String, message: String) { val result = pending; pending = null; result?.error(code, message, null) }
    fun close() { finishError("MAIL_CANCELLED", "Authorization ended when the app closed.") }
}
