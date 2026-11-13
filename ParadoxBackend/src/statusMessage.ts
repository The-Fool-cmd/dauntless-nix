/*
 * dauntless-nix: configurable login-screen status line (modified version of Mystic Paradox; see NOTICE.md).
 * SPDX-License-Identifier: AGPL-3.0-only
 */
// The status line the login screen shows. MYSTICPARADOX_STATUS_MESSAGE replaces the text (every language) on a server
// that is not the official one; MYSTICPARADOX_STATUS_MESSAGE=off hides it. Unset keeps the official text.
const OFFICIAL_STATUS_MESSAGE = "Welcome to Mystic Paradox!";
export function StatusPayload(environment: NodeJS.ProcessEnv = process.env): Record<string, unknown> {
    const Configured = environment.MYSTICPARADOX_STATUS_MESSAGE?.trim();
    if (Configured !== undefined && /^(off|false|0|no)$/i.test(Configured)) return { "show-status": false };
    const Text = Configured ? Configured.slice(0, 200) : OFFICIAL_STATUS_MESSAGE;
    const Payload: Record<string, unknown> = { "show-status": true };
    for (const Language of ["en", "fr", "it", "es", "de", "pt", "ru", "ja"]) Payload[Language] = Text;
    return Payload;
}
