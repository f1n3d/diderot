# Sign-in and authentication

As of October 9, 2026, checked against Docmost v0.96.0 (server code, and tests against real instances).

## What works and what doesn't

| Sign-in method | Docmost license | In the app | Note |
|---|---|---|---|
| Email and password | any, also none | works, native | Docmost's own MFA (TOTP) with a native code step |
| LDAP | Business and up | works, native | |
| SSO (OIDC, SAML) with password, TOTP or similar at the identity provider | Business and up | works, in the in-app browser | Independent of the provider; the instance decides the identity provider. Tested with Authentik (password plus TOTP) against a production instance |
| SSO with a passkey at the identity provider | Business and up | postponed | Works only with an associated domain, see [Passkeys](#passkeys) |
| Google sign-in | Business and up | probably not | Google doesn't allow sign-ins in embedded browsers (not tested) |
| API key | Business and up | not implemented | technically possible, see [Other ways](#other-ways) |
| Docmost OAuth | Business and up | not usable | its tokens work for only part of the API |

SSO, MFA, LDAP, API keys and OAuth are license features in Docmost (Enterprise Edition, from the Business license up). Without a license, an instance offers only email and password.

## How the SSO sign-in works

1. The app opens its own browser (WKWebView) with the instance's SSO start (`/api/sso/<type>/<id>/login`) or the web sign-in (`/login`).
2. Signing in at the identity provider (Authentik, Keycloak, Microsoft Entra …) works there as on the web.
3. Docmost then sets its session cookie `authToken` (HttpOnly). The app reads it from its browser's cookie store, discards the store and sends the token as `Authorization: Bearer` from then on.

The session shows up in Docmost's device sessions and expires like a browser session. After that, you sign in to the app again.

## Passkeys

Passkeys for signing in to the app are postponed for now (decided on October 9, 2026).

WebKit allows passkeys (WebAuthn) in an embedded browser only for domains associated with the app (Associated Domains, service `webcredentials`). Without that, the browser refuses the passkey request and Authentik shows "auth was canceled or timed out". This also happens after entering the password, when Authentik offers the passkey first as the second factor. Tested on October 9, 2026, with Authentik.

If the account also has TOTP, signing in still works: after the error at Authentik, choose the other method and enter the TOTP code. Accounts that only have a passkey can't get into the app without an associated domain.

The association takes two parts:

1. An AASA file on the identity provider's domain, served at `https://<idp-domain>/.well-known/apple-app-site-association`. It must come as JSON over HTTPS, without redirects, and reachable for Apple's CDN (exempt it from bot protection):
   ```json
   {"webcredentials":{"apps":["<TEAM_ID>.io.github.f1n3d.diderot"]}}
   ```
2. The domain in the app's entitlement: `com.apple.developer.associated-domains` with `webcredentials:<idp-domain>`.

So:

- The list of domains is part of the signed app and fixed at build time. A field in the app can't extend it; every new domain needs a new app version or a build of its own.
- It only works with identity providers whose domain the operator controls, such as Authentik or Keycloak. With hosted providers like Microsoft Entra, Okta or Google, nobody can place the file.
- The AASA file names the app's team ID and bundle ID. If the app changes its developer team, every operator has to update their file.
- An exception for companies: on MDM-managed devices, device management can hand over the domains at runtime. The app then needs the entitlement `com.apple.developer.associated-domains.mdm-managed`.

In iOS's system browser (ASWebAuthenticationSession), passkeys work with every provider. There, however, the app can't get at Docmost's session cookie.

## Other ways

- **Docmost OAuth:** the usual way for native apps exists: public clients with PKCE, a custom URL scheme as the redirect URI, access tokens for 1 hour, refresh tokens for 30 days. Docmost accepts these tokens only at 23 endpoints meant for MCP, though. Among others, the editor's collab token, notifications, favorites, deleting and the trash, history, export and uploads are missing. That holds for v0.96.0 and upstream as of October 9, 2026. Once Docmost accepts the tokens more widely, this is the best solution: passkeys with every provider, no work for the operator.
- **API keys:** they work as bearer tokens for the whole API, including the editor. You would create the key on the web and paste it into the app. Not implemented for now.

## Decisions (October 9, 2026)

- The app signs in with a password (any instance), with LDAP, and with SSO through the in-app browser. Which identity provider sits behind Docmost doesn't matter for that.
- Tested: SSO through Authentik with password and TOTP against a production instance. The app takes over the session; spaces and content load. The UI tests against the dev instance cover the password sign-in.
- Passkey sign-in is postponed for now. It only works with an associated domain: feasible for single, known instances, but not a general solution.
- Accounts with only a passkey have no way into the app for now. Candidates are API keys and Docmost OAuth, once Docmost accepts its tokens more widely.
