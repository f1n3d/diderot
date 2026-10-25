# App Store listing

The texts for App Store Connect, in English and German, with the limits Apple sets. Keep them in step with the app.

## Both languages

| Field | Value |
| --- | --- |
| Name | Diderot |
| Primary category | Productivity |
| Secondary category | Business |
| Price | Free |
| Support URL | https://github.com/f1n3d/diderot/issues |
| Marketing URL | https://github.com/f1n3d/diderot |
| Privacy policy URL | https://github.com/f1n3d/diderot/blob/main/Docs/Privacy.md |
| App privacy | Data Not Collected |
| License agreement | Apple's standard agreement |

## English

**Subtitle** (30 characters at most)

> For your Docmost wiki

**Promotional text** (170 at most)

> Read and edit your Docmost pages in a native app for iPhone and iPad, live with everyone on the web and offline too.

**Description** (4000 at most)

> Diderot brings your Docmost wiki to iPhone and iPad as a native app. Sign in to the Docmost server you or your team run, and read and write pages with the ease of an iOS app.
>
> WRITE AS ON THE WEB
> • Headings, lists, tasks, tables, quotes, callouts, toggles, code with syntax highlighting, formulas, Mermaid diagrams, images, videos, PDFs and attachments
> • Every slash command of the web editor, mentions of pages and people, links and comments
> • Changes appear live for everyone on the web, and theirs for you
>
> AT HOME ON iOS
> • Autocorrect, dictation, text replacements and Writing Tools work as in any app
> • Keyboard shortcuts and multiple windows on the iPad
> • VoiceOver and larger text sizes throughout
>
> ALSO OFFLINE
> • Pages you opened stay readable without a network
> • Changes made offline go out once you're back online
>
> DATABASES, SEARCH, ACTIVITY
> • Tables and boards of Docmost databases, with editing and new entries (needs a Docmost license with databases, Business and up)
> • Search across your spaces, favorites, recently opened pages, and the trash
> • The activity feed with mentions and comments
>
> PRIVATE BY DESIGN
> • No analytics, no ads, no tracking: everything goes only to your own server
> • Your sign-in stays in the Keychain; copies for offline reading can be read only while the device is unlocked
> • Several servers side by side; sign in with a password, LDAP or single sign-on
>
> Diderot is open source (MIT) and works with Docmost 0.96. It is an independent project, not affiliated with Docmost.

**Keywords** (100 at most, separated by commas)

> docmost,wiki,notes,knowledge base,documentation,self-hosted,editor,team,pages,markdown

## Deutsch

**Untertitel** (höchstens 30 Zeichen)

> Für dein Docmost-Wiki

**Werbetext** (höchstens 170)

> Lies und bearbeite deine Docmost-Seiten in einer nativen App für iPhone und iPad, live mit allen im Web und auch offline.

**Beschreibung** (höchstens 4000)

> Diderot bringt dein Docmost-Wiki als native App auf iPhone und iPad. Melde dich bei dem Docmost-Server an, den du oder dein Team betreibt, und lies und schreibe Seiten so leicht wie in jeder iOS-App.
>
> SCHREIBEN WIE IM WEB
> • Überschriften, Listen, Aufgaben, Tabellen, Zitate, Hinweise, Aufklapper, Code mit Syntaxhervorhebung, Formeln, Mermaid-Diagramme, Bilder, Videos, PDFs und Anhänge
> • Alle Slash-Befehle des Web-Editors, Erwähnungen von Seiten und Personen, Links und Kommentare
> • Änderungen erscheinen live bei allen im Web, und deren Änderungen bei dir
>
> ZUHAUSE AUF iOS
> • Autokorrektur, Diktat, Textersetzungen und Schreibtools funktionieren wie in jeder App
> • Tastaturkurzbefehle und mehrere Fenster auf dem iPad
> • VoiceOver und größere Schrift überall
>
> AUCH OFFLINE
> • Geöffnete Seiten bleiben ohne Netz lesbar
> • Offline gemachte Änderungen gehen raus, sobald du wieder online bist
>
> DATENBANKEN, SUCHE, AKTIVITÄT
> • Tabellen und Boards von Docmost-Datenbanken, mit Bearbeiten und neuen Einträgen (braucht eine Docmost-Lizenz mit Datenbanken, ab Business)
> • Suche über deine Bereiche, Favoriten, zuletzt geöffnete Seiten und der Papierkorb
> • Die Aktivität mit Erwähnungen und Kommentaren
>
> PRIVAT VON ANFANG AN
> • Keine Analyse, keine Werbung, kein Tracking: Alles geht nur an deinen eigenen Server
> • Deine Anmeldung bleibt im Schlüsselbund; Kopien zum Offline-Lesen sind nur bei entsperrtem Gerät lesbar
> • Mehrere Server nebeneinander; Anmeldung per Passwort, LDAP oder Single Sign-on
>
> Diderot ist Open Source (MIT) und funktioniert mit Docmost 0.96. Es ist ein unabhängiges Projekt und nicht mit Docmost verbunden.

**Schlüsselwörter** (höchstens 100, durch Kommas getrennt)

> docmost,wiki,notizen,wissensdatenbank,dokumentation,selbst gehostet,editor,team,seiten,markdown

## App Review

Notes for Apple's reviewers (English, 4000 characters at most). They answer the six points App Review asks new developer accounts (Guideline 2.1, Information Needed, October 2026), and the same text goes into the reply in App Store Connect. The demo account's email and password go into the "Sign-in required" fields, never into this file. App Store Connect takes one attachment here: `Diderot-AppReview.mp4`, the screen recording of the release build on an iPhone (launch to sign-out), then the databases on a licensed server.

> 1. Screen recording
> The attached "Diderot-AppReview.mp4" has two parts. Part 1 (0:00–3:13) was recorded on an iPhone 16 Pro Max with iOS 27.0.1, running build 1.0.0 (12) from TestFlight. It starts with launching the app and shows connecting to a Docmost server, signing in, reading and editing pages, comments, search, creating a page and signing out. The few seconds in which the password manager fills in the sign-in are cut out, as it shows private entries. Part 2 (from 3:16) shows databases on a licensed server, recorded in the iOS Simulator (see 3).
> • Accounts: the app doesn't create accounts. Accounts belong to the Docmost server that an organization or person runs, and its administrators invite and remove members. The app only signs in to existing accounts, so it has no registration or deletion flow.
> • User-generated content: pages and comments come only from members of the same private workspace, on a server their own organization runs. There is no public content and no way to reach people outside the workspace. The workspace's administrators decide who is a member and can deactivate or remove members; space administrators can delete any page or comment.
> • Paid content: none. The app is free, with no in-app purchases, subscriptions, ads or links to buy anything.
>
> 2. Purpose and audience
> Docmost is an open-source wiki that anyone can run on their own server for free. Diderot is a native iPhone and iPad app for it: people who keep notes, documentation or a knowledge base in Docmost can read and edit their pages on the go, offline too, with dictation, autocorrect, VoiceOver and keyboard shortcuts. Without the app they have only the website, which is hard to write in on a phone. Diderot is for anyone who uses a Docmost server (individuals, families, clubs, teams and companies), not for one particular organization.
>
> 3. Trying the app
> • Open the app, enter the server address <DEMO_URL> and tap Continue.
> • Sign in with the demo account below (email and password).
> • The space "Product Team" has sample pages and a comment thread on "Weekly Sync". Everything can be edited, and you can create pages and write comments.
> • Databases (tables and boards) need a Docmost license with databases (Business and up) on the server, which the demo server doesn't have. Part 2 of the attached video shows them on a licensed server.
> No sample files are needed.
>
> 4. External services
> • The Docmost server the user signs in to (for the review: our demo server). Content and sign-in go only there.
> • Sign-in by email and password, LDAP or single sign-on, as the server offers. Single sign-on shows the server's sign-in page inside the app, which forwards to the identity provider the organization set up.
> • Links and embeds that users add to pages (for example YouTube or Figma) open in Safari's in-app view only when tapped.
> • Draw.io and Excalidraw drawings are edited in the Docmost server's own web editor, as on the web.
> Nothing else: no analytics, crash reporting, advertising, payment or AI services. The open-source libraries the app includes run on the device (Settings › About › Licenses).
>
> 5. Regions
> The app works the same in every region. It is offered everywhere except mainland China, in English and German.
>
> 6. Regulation and third-party material
> Diderot isn't in a regulated industry and contains no protected third-party material. Docmost is open-source software; Diderot is an independent open-source client (MIT license, https://github.com/f1n3d/diderot) that talks to Docmost servers through their web API, as Docmost's own website does. It contains no Docmost code and isn't affiliated with Docmost; the name only says which servers the app works with.
