# Estimates (Quotes) API Contract

**Audience:** anyone building a client for the Estimating Agent, whether the existing web app
(`technician-copilot`) or the new mobile app.
**Scope:** estimates/quotes and the estimate chat. The general job-page Copilot chat (SSE
stream) is covered in [MOBILE_COPILOT_INTEGRATION.md](MOBILE_COPILOT_INTEGRATION.md) and
[`copilot-contract.ts`](../copilot-contract.ts). It appears here only where the two overlap.

> **Source of truth.** This contract comes from the web client's service layer
> ([`quotesService.ts`](../src/services/quotesService.ts),
> [`connectionsService.ts`](../src/services/connectionsService.ts)) and the screens that call
> it. The server is **copilot-server** (`/api/v1/quotes`). If the server and this document
> disagree, the server wins and this document should be fixed.

---

## 1. The split: core vs client

The rule is that **clients can change, but the contract can't.** The web app and the mobile app
are both thin clients over the same API. All business logic lives in the core (copilot-server).

| Core (server) owns | Client owns |
|---|---|
| The estimating agent: turning speech/text into line items | Capturing input (text, voice, photos) |
| **All money math**: markup, line totals, tax, option totals | Displaying the numbers exactly as returned |
| Line-item flags and `blockingFlagCount` | Showing flags and gating the Complete button on `blockingFlagCount` |
| Catalog / web pricing (`priceItem`) | Deciding *when* to request a price (auto-trigger rule, §7.3) |
| Draft/Completed state machine and its 409s | Hiding edit controls on Completed quotes |
| Posting to QuickBooks / ZenTrades | Showing sync state and offering a retry |
| Rendering proposal PDF/DOCX and sending email | Previewing, downloading and sharing the file |
| Persisting chat history, including answer metadata | Rendering history, optimistic echo of the user's own turn |

**Hard rules for every client**

1. **Never compute money.** Every price in `lineItems` already includes markup. Don't apply
   `markupPercent` again, and don't add up totals yourself. Use `total`, `taxAmount`,
   `totalWithTax` and `optionTotals`.
2. **Every write returns the new state; replace your copy with it.** Most writes return the whole
   `Quote`. Apply the response and don't patch local state by hand.
3. **Don't overlap your own writes on one quote.** There is no optimistic locking. Two in-flight
   PATCHes each return a full snapshot, and whichever arrives last silently discards the other.
   Serialise writes per quote (the web app uses one `busy` flag).
4. **Treat unknown enum values safely.** An unrecognised line-item flag counts as **blocking**
   (§3.3). An unrecognised chat block `kind` renders nothing.
5. **Expect optional fields to be missing.** Fields marked `?` below may be absent on an older
   server (web and API deploy independently). Where it matters, the default is spelled out.

---

## 2. Conventions

### 2.1 Base URLs

| Name | Web env var | Used for |
|---|---|---|
| **Copilot API** | `VITE_COPILOT_BASE_URL` → `${base}/api/v1` | Everything in this document |
| **Auth API** | `VITE_API_BASE_URL` (e.g. `…/api`) | Login and token refresh only |

### 2.2 Headers

| Header | When | Value |
|---|---|---|
| `Authorization` | Always | `Bearer <access_token>` |
| `Content-Type` | JSON bodies only | `application/json`. **Omit it for multipart**, so the HTTP client sets the boundary. |
| `X-Device-Timezone` | Always | IANA zone, e.g. `America/Chicago` (fallback `UTC`) |

Dev-only alternative to `Authorization` (local servers, never production): `X-Dev-Bypass: true`
plus `X-User-Id`, `X-User-Email`, `X-User-Role`, `X-Company-Id`.

All data is scoped server-side to the signed-in technician and their company. Clients never send
a user ID or company ID.

### 2.3 Auth and token refresh

- **Login:** `POST {AUTH}/auth/login` `{ email, password }`, with the email trimmed and
  lowercased by the client. The response is `{ user, tokens: { accessToken, refreshToken } }`.
- **Refresh:** `POST {AUTH}/auth/refresh` `{ refresh_token }`. Tolerate both wrapped
  (`{ data: … }`) and bare bodies, and any of `access_token | accessToken | token |
  tokens.accessToken`. A new refresh token may also be returned; store it if present.
- **On `401` from the Copilot API:** refresh **once** (single-flight, shared by all concurrent
  requests), then retry the original request with the new token. Log out only if the refresh
  itself fails.

### 2.4 Response envelope

Success:

```json
{ "data": <payload> }
```

Error:

```json
{ "error": { "message": "Human-readable reason", "code": "OPTIONAL_MACHINE_CODE", "options": [ … ] } }
```

- Clients unwrap `data` and show `error.message` to the user as-is (it's written for humans).
- Branch on `error.code` where one is defined (§10). `options` only appears with
  `OPTION_CHOICE_REQUIRED`.
- **Binary endpoints** (PDF/DOCX) return the raw file, not the envelope. Take the filename from
  `Content-Disposition: …; filename="…"`.

### 2.5 Timeouts

| Call | Typical | Suggested client timeout |
|---|---|---|
| Most reads/writes | < 1 s | 30 s |
| `POST /quotes/:id/messages` (agent turn) | several seconds, sometimes longer | 120 s |
| `POST /quotes/:id/items/:itemId/price` | **15–30 s** on a cold search | 60 s |
| Login | < 1 s | 10 s (fail fast on bad field networks) |

---

## 3. Data model

TypeScript is used as the schema language. The canonical definitions are in
[`quotesService.ts`](../src/services/quotesService.ts). Copy them rather than retyping them.

### 3.1 Quote

```ts
interface Quote {
  id: string;
  conversationId: string;
  status: "DRAFT" | "COMPLETED";
  createdAt: string;            // ISO 8601
  updatedAt: string;
  completedAt: string | null;

  lineItems: QuoteLineItem[];
  /** Materials markup %. Already applied to every price. Only used to fill the Markup input. */
  markupPercent: number;

  // Customer (editable in DRAFT only)
  customerId: number | null;    // linked customer; null until picked/created
  customerName: string | null;
  customerAddress: string | null;
  customerPhone: string | null;
  customerEmail: string | null; // read live from the linked customer, never stored on the quote

  // Money (all server-computed)
  total: number;                // base scope, BEFORE tax
  taxRatePercent: number | null;// snapshot. null = "no tax line at all"; 0 = "deliberate 0%, still printed"
  salesTaxId: number | null;
  taxableSubtotal: number;
  taxAmount: number;
  totalWithTax: number;
  optionTotals?: QuoteOptionTotal[];
  chosenOptionGroup?: string | null; // captured at completion

  // QuickBooks sync
  qboEstimateId: string | null;
  qboSyncedAt: string | null;
  qboSyncError: string | null;  // set + qboEstimateId set = posted once, later attempt failed

  // ZenTrades linkage + sync (same meaning as the qbo trio)
  ztTicketId: string | null;
  ztEstimateId: string | null;
  ztSyncedAt: string | null;
  ztSyncError: string | null;

  /** Number of line items with a blocking flag. > 0 disables "Mark as completed". */
  blockingFlagCount: number;
}

interface QuoteWithMessages extends Quote {
  messages: QuoteMessage[];
}

interface QuoteOptionTotal {
  name: string;                 // e.g. "Option A – Replace unit"
  total: number;                // this option's lines only
  combinedTotal: number;        // base + option, BEFORE tax
  taxAmount: number;            // 0 when the quote has no rate
  combinedTotalWithTax: number; // what the customer pays for this option
}
```

**Display title:** `"<customerName> : <createdAt as medium date + short time>"`, or just the date
when there's no name.

### 3.2 Line item

```ts
interface QuoteLineItem {
  id: string;
  description: string;
  quantity: number | null;
  unit: string | null;
  unitPrice: number | null;
  totalPrice: number | null;
  pricebookCode: string | null;
  isLabor: boolean;             // labor is exempt from markup
  taxable: boolean;             // labor/fees typically false
  sortOrder: number;

  /** Option group ("Option A – …"). null/undefined = base scope. */
  optionGroup?: string | null;

  flags: LineItemFlag[];
  ambiguousAction: AmbiguousAction | null;

  // Pricing provenance
  product: LineItemProduct | null; // catalog source (e.g. Home Depot); null = unpriced or own pricebook
  priceEstimated?: boolean;        // price came from a live web search, not the catalog
  estimateLink?: string | null;    // product URL, or a Home Depot search URL
  priceSource?: string | null;     // pricebook name / "Home Depot — online fallback" / null = manual. Review screen only.
  searchTerm?: string | null;      // catalog-shaped term; the auto QBO item name

  // QuickBooks item mapping
  qboItemId?: string | null;       // null = auto match/create at post time
  qboItemName?: string | null;
}

interface LineItemProduct {
  productId: string | null;
  link: string | null;          // render links from THIS field, never from model-written text
  brand: string | null;
  rating: number | null;
  packageQuantity: number | null;
  provisional: boolean;         // true until the technician accepts the line
}

interface AmbiguousAction {
  action: "remove" | "update";
  candidateItemIds: string[];   // the lines the technician might have meant
  referenceText: string;        // what they said, e.g. "the pipe"
  fields?: { description?: string; quantity?: number; unit?: string };
}
```

**Sections on the estimate screen:** base-scope materials (`!isLabor && !optionGroup`), base-scope
labor (`isLabor && !optionGroup`), then one section per distinct `optionGroup`, sorted by
`sortOrder`.

### 3.3 Line-item flags

| Flag | Label | Blocking | How the technician clears it |
|---|---|---|---|
| `missing_quantity` | Missing Qty | yes | Set `quantity` (PATCH) |
| `unmatched` | Unmatched / Unpriced | yes | Auto price search (§7.3), or type a price |
| `ambiguous` | Ambiguous | yes | Pick a candidate: PATCH `{ resolveCandidateId }`. Tap only, not voice. |
| `agent_suggested` | Agent-Suggested · Unconfirmed | yes | PATCH `{ confirm: true }`, or remove the line |
| `estimated_price` | Estimated Price · Unconfirmed | yes | Type a **different** price, or remove the line |
| `manually_edited` | Manually Edited | no | Informational |
| *(anything else)* | show the raw key | **yes** | Future server flags. Treat as blocking so the UI matches `blockingFlagCount`. |

Flags are computed by the server on every request. Clients never set them.

### 3.4 Photos attached to a quote

```ts
interface QuoteImage {
  id: string;
  url: string;          // time-limited URL; refetch the list rather than caching it long-term
  mimeType: string;
  filename: string | null;
  createdAt: string;
}
```

### 3.5 Chat message

```ts
interface QuoteMessage {
  id: string;
  senderType: "USER" | "AI" | "SYSTEM";
  content: string;              // markdown for AI turns
  contentType?: string;         // "TEXT" | "IMAGE" | …
  attachments?: QuoteMessageAttachment[];
  metadata?: QuoteMessageMetadata | null;
  createdAt: string;
}

interface QuoteMessageAttachment {
  id: string;
  url?: string;
  type?: string;                // mime type
  filename?: string;
  size?: number;
  metadata?: { s3Key?: string } | null;
}

/** Known keys. Treat everything as optional. */
interface QuoteMessageMetadata {
  // AI turns
  blocks?: CopilotBlock[];      // structured content; the source of truth when present (§6.3)
  thinkingDuration?: number;    // seconds, for "Thought for Ns"

  // USER turns that answered a question card
  answers?: string[];               // flat chosen values
  questionAnswers?: QuestionAnswer[];// values tied to their questions
  answeredMessageId?: string;       // id of the AI message whose card was answered
}

interface QuestionAnswer {
  questionId: string;           // = FollowUpQuestion.id
  question: string;
  value: string;
  fromOther?: boolean;          // typed into "Other" rather than picked
}
```

`CopilotBlock` and `FollowUpQuestion` are defined in [`copilot-contract.ts`](../copilot-contract.ts).

---

## 4. Lifecycle

```
            POST /quotes                     POST /quotes/:id/complete
  (none) ───────────────▶  DRAFT  ─────────────────────────────────────▶  COMPLETED
                             ▲      (posts to QuickBooks server-side)        │
                             └───────────── POST /quotes/:id/reopen ─────────┘
```

| Operation | DRAFT | COMPLETED |
|---|---|---|
| Chat turn, voice, attach/remove photo | ✅ | ❌ composer hidden ("Completed and frozen — move it back to Draft to edit") |
| Add / edit / remove / price line items | ✅ | ❌ server returns 409 |
| PATCH quote (markup, customer, tax) | ✅ | ❌ server returns 409 |
| Complete | ✅ only when `blockingFlagCount == 0` | — |
| Reopen | — | ✅ |
| Download / preview / email proposal | ✅ | ✅ |
| Sync to QuickBooks / ZenTrades (manual retry) | ❌ | ✅ |

One chat = one quote. Reopening a quote brings back the same conversation and line items exactly
as they were.

---

## 5. Quote endpoints

All paths are relative to `{COPILOT}/api/v1`.

### 5.1 List quotes

`GET /quotes?status=DRAFT|COMPLETED` → `Quote[]` (without messages)

Shows the Drafts and Completed tabs. For drafts, show "N item(s) need attention" when
`blockingFlagCount > 0`.

### 5.2 Create quote

`POST /quotes`

```json
{}                              // blank estimate
{ "ztTicketId": "12345" }       // linked to a synced ZenTrades job; the chat opens pre-seeded
```

→ `Quote`. The client then navigates to the new quote's detail screen.

### 5.3 Get quote (with chat history)

`GET /quotes/:id` → `QuoteWithMessages`

Load this once when the detail screen opens. Also use it to reconcile after a burst of concurrent
writes (§7.3).

### 5.4 Update quote-level fields (DRAFT only)

`PATCH /quotes/:id` → `Quote`

Send any subset:

```ts
{
  markupPercent?: number;
  customerName?: string | null;
  customerAddress?: string | null;
  customerPhone?: string | null;
  customerId?: number | null;   // link (or unlink with null) the billed customer
  salesTaxId?: number | null;   // null = deliberately UNTAXED (recorded as a decision, not reset at completion)
}
```

### 5.5 Complete

`POST /quotes/:id/complete` → `Quote`

```json
{}                                          // first attempt
{ "chosenOption": "Option A – Replace unit" } // retry after OPTION_CHOICE_REQUIRED
```

Completing is what posts the estimate to QuickBooks (server-side). Handle these errors:

- `409 OPTION_CHOICE_REQUIRED` with `error.options: QuoteOptionTotal[]`: the quote has
  either/or options. Ask the technician which option the customer chose (show each option's
  `combinedTotalWithTax`), then retry with `chosenOption: <name>`.
- `TAX_RATE_UNAVAILABLE`: the quote's saved tax rate no longer has an active tax code in the
  connected QuickBooks file. Show `error.message` and open the tax-rate picker (§9.5) so they can
  pick another rate, then retry.

Keep "Mark as completed" disabled while `blockingFlagCount > 0` or while an option prompt is open.

### 5.6 Reopen

`POST /quotes/:id/reopen` → `Quote` (status back to `DRAFT`)

---

## 6. Estimate chat

The chat is how the technician builds the estimate: they speak or type, and the agent adds or
changes line items. It is **request/response, not streaming**. One POST runs one full agent turn.

### 6.1 Send a turn

`POST /quotes/:id/messages`

```ts
{
  content: string;                 // required; the technician's text (or transcribed speech)
  imageUrls?: string[];            // optional; images for the agent to see (vision). Omit if empty.
  // Only when answering a question card; send both or neither:
  answers?: QuestionAnswer[];      // the server also accepts a bare string[]
  answeredMessageId?: string;      // the AI message whose card is being answered
}
```

→ `{ reply: QuoteMessage, quote: Quote }`

- Append `reply` to the message list and **replace** the quote with `quote`. A turn can add,
  change or remove line items, so the Estimate tab must re-render from this snapshot.
- **Optimistic echo:** add the user's bubble right away with a local id (e.g. `local-<ts>`). For
  a card answer, give it the same `metadata` the server will store (`answers` as values,
  `questionAnswers`, `answeredMessageId`) so the card locks at once. **If the request fails,
  remove the optimistic bubble.** Otherwise a card stays locked on answers the server never got,
  with no way to retry.
- Show a "Updating the estimate…" indicator while waiting. Allow only one turn in flight at a time.

### 6.2 Voice input

`POST /voice/transcribe` (Copilot API, JSON)

```json
{ "audioBase64": "<base64 without data: prefix>", "mimeType": "audio/webm", "language": "en" }
```

→ `{ "success": true, "text": "…" }` (**not** wrapped in `data`)

Strip codec suffixes from the mime type (`audio/webm;codecs=opus` → `audio/webm`). On mobile, send
whatever the recorder produces (`audio/m4a`, `audio/aac`, …) with the matching mime type. The
transcript is sent as `content` in §6.1. The client can let the user review it first or send it
straight away.

### 6.3 Rendering history

For each message in `messages`, oldest first:

1. **Hide answer echoes.** A `USER` message whose `metadata.questionAnswers` has at least one
   valid entry *and* which has `metadata.answeredMessageId` is shown **on the card it answered**,
   not as its own bubble. If either part is missing, render it as a normal bubble so the answer
   never disappears.
2. **AI messages with `metadata.blocks`:** render the blocks (one component per `block.kind`, same
   as the Copilot chat). Otherwise render `content` as markdown.
3. **Question cards** (`kind: "questions"`): each question has options plus a free-text "Other"
   (always allowed). Collect **all** answers, then send **one** turn:
   - `content`: the single answer's value if there is one question; otherwise
     `"<question>\n→ <answer>"` pairs joined by a blank line (the model needs the question context)
   - `answers`: one `QuestionAnswer` per question
   - `answeredMessageId`: the id of the AI message that holds the card

   Once answered (found via `answeredMessageId` in a later USER message), the card shows the
   chosen answers and is locked.
4. **Image messages** (`contentType: "IMAGE"` with image `attachments`): render the thumbnails.
   The server creates these when photos are attached (§8).
5. Show `metadata.thinkingDuration` as "Thought for Ns" when present.
6. When the quote is `COMPLETED`, render history read-only: no composer, and no interactive cards
   or chips.

### 6.4 Photos vs the agent (current product decision)

The composer's camera/gallery buttons **attach photos to the quote** (§8). They do **not** go to
the agent: no captioning, no analysis. Only `imageUrls` on a chat turn reaches the model, and the
web client doesn't use it in the estimate chat today. A mobile client should do the same unless
the product decision changes.

---

## 7. Line-item endpoints (DRAFT only)

### 7.1 Add

`POST /quotes/:id/items` → `QuoteLineItem` (**just the line**, not the whole quote. Refetch the
quote or merge it in.)

```ts
{
  description: string;          // required
  quantity?: number | null;
  unit?: string | null;
  unitPrice?: number | null;
  totalPrice?: number | null;
  isLabor?: boolean;            // set from which section's Add button was tapped. Decides markup exemption + taxable default.
  taxable?: boolean;            // override the default (!isLabor)
  qboItemId?: string | null;
  qboItemName?: string | null;
}
```

Older servers ignore `taxable`/`qboItemId`. Compare what comes back rather than assuming they
were applied. The web app refetches with `GET /quotes/:id` after adding.

### 7.2 Update

`PATCH /quotes/:id/items/:itemId` → `Quote`

Send only what changed. The same endpoint handles several actions:

| Intent | Body |
|---|---|
| Edit fields | `{ description?, quantity?, unit?, unitPrice?, totalPrice? }` |
| Move between material/labor | `{ isLabor: boolean }` |
| Toggle taxable | `{ taxable: boolean }` |
| Pick a QuickBooks item | `{ qboItemId, qboItemName }` (both `null` = back to auto) |
| Confirm an agent-suggested line | `{ confirm: true }` |
| Resolve an ambiguous reference | `{ resolveCandidateId: "<one of ambiguousAction.candidateItemIds>" }` |

To clear `estimated_price`, send a `unitPrice` that differs from the current one. Only send a
field when its value has actually changed.

### 7.3 Price search

`POST /quotes/:id/items/:itemId/price` with body `{}` → `Quote` (15–30 s cold)

**Auto-trigger rule (client-side):** while the quote is DRAFT, every line flagged `unmatched`
that hasn't already been searched on this screen is priced automatically, **all at once**. The
server paces the searches. There's no button. Apply each response as it arrives, then do one
final `GET /quotes/:id` once all have settled, because concurrent snapshots can arrive out of
order. When the technician edits a line, forget that it was searched, so a reworded line gets a
new search. Failures are silent: the `unmatched` flag stays, and the server retries on later
agent turns.

### 7.4 Remove

`DELETE /quotes/:id/items/:itemId` → `Quote`

---

## 8. Quote photos

Photos attached to the quote appear on the Estimate tab, in the chat timeline and at the end of the
proposal documents. They are editable in DRAFT only.

| Call | Request | Response |
|---|---|---|
| List | `GET /quotes/:id/images` | `QuoteImage[]` |
| Upload | `POST /quotes/:id/images`, `multipart/form-data`, one `images` field per file (multiple allowed, `image/*` only) | `QuoteImage[]` (**every** image on the quote, not only the new ones) |
| Remove | `DELETE /quotes/:id/images/:imageId` | `QuoteImage[]` (what's left) |

The server also saves a USER chat message ("Photo attached to the quote" / "N photos attached to
the quote", `contentType: "IMAGE"`, with the images as attachments). A client can show a local
copy straight away; after a reload the stored message looks the same.

**React Native multipart:** append `{ uri, name, type }` objects to `FormData` under `images`, and
don't set `Content-Type` yourself.

---

## 9. Documents, delivery and integrations

### 9.1 Proposal documents (binary, any state)

| Call | Returns | Use |
|---|---|---|
| `GET /quotes/:id/proposal-pdf` | PDF | In-app preview, and what gets emailed |
| `GET /quotes/:id/proposal-docx` | DOCX | "Download proposal", in the company's saved proposal format |
| `GET /quotes/:id/docx` | DOCX | The quote/invoice document (the company's own template) |

On mobile, save the file to app storage and open the OS share sheet or viewer.

### 9.2 Email the proposal

1. `GET /quotes/:id/email-draft` → `{ to, subject, body }`. Fetch this together with the PDF so
   the review screen can show both.
2. The technician edits the draft.
3. `POST /quotes/:id/email` with `{ to, subject, body }` → `{ sent: boolean, to: string }`. The
   server sends it with the proposal attached.

The email body comes from the company's template (admin setting,
`GET/PUT /companies/proposal-email-template`, not needed by the technician app).

### 9.3 Push to QuickBooks (COMPLETED only)

`POST /quotes/:id/qbo` → `{ estimateId: string, updated: boolean }` (**not** a `Quote`)

This re-runs the completion post, updating the existing QuickBooks estimate rather than creating a
duplicate. Afterwards, `GET /quotes/:id` to refresh the `qbo*` fields. Only offer it when
QuickBooks is connected (§9.4) and the quote is COMPLETED. When `qboSyncError` is set, show it
with a Retry button.

### 9.4 Push to ZenTrades (COMPLETED + linked)

`POST /quotes/:id/zt` → `Quote`. Only offer it when ZenTrades is connected, `ztTicketId` is set and
the quote is COMPLETED.

### 9.5 Supporting reads used by the estimate screens

All under `/companies`. Every role can use them.

| Call | Returns | Used for |
|---|---|---|
| `GET /companies/connections` | `ConnectionsStatus` (`{ canManage, qbo, zt }`) | Whether to show QuickBooks/ZenTrades features. `qbo.environment` (sandbox/production) decides deep-link targets. **If this read fails, hide all integration features.** |
| `GET /companies/connections/zt/jobs?q=` | `ZtJob[]` | "New estimate from job" picker (then §5.2 with `ztTicketId`) |
| `GET /companies/connections/qbo/items` | `{ id, name }[]` | Per-line QuickBooks item dropdown. 409 until connected, so on any error hide the dropdown. |
| `GET /companies/qbo/customers?q=` | `CustomerOption[]` | Customer picker search (CLARA's own customers; works without QuickBooks) |
| `POST /companies/qbo/customers` | `{ customerId, name, qboId, addressMissing? }` | Create a customer from the estimate. Body: `{ name, email?, phone?, address?, parentId? }`. Then PATCH the quote with `{ customerId }`. If `addressMissing` is non-empty, ask for those parts of the address; the server never guesses them. |
| `GET /companies/sales-tax` | `SalesTaxSettings` (`{ taxSource, taxEnabled?, taxEnforced?, taxEnforcedBy?, rates }`) | Tax-rate picker. Offer rates where `isActive && usable`. Pick → PATCH quote `{ salesTaxId }`. Treat a missing `taxEnabled` as **on**. |

The full types are in [`connectionsService.ts`](../src/services/connectionsService.ts). Admin-only
endpoints there (connect/disconnect/sync, tax writes, markup defaults) aren't part of the
technician app's contract.

---

## 10. Error catalogue

| HTTP | `error.code` | Where | Client behaviour |
|---|---|---|---|
| 401 | — | any | Refresh once and retry (§2.3). Log out if the refresh fails. |
| 403 | — | admin-only endpoints | Hide the control. Trust `connections.canManage` over any local role check. |
| 409 | `OPTION_CHOICE_REQUIRED` | complete | Show the option prompt from `error.options`, retry with `chosenOption` |
| — | `TAX_RATE_UNAVAILABLE` | complete | Show the message, open the tax-rate picker |
| 409 | — | any write on a COMPLETED quote | Shouldn't happen if the UI respects state. Show the message and refetch. |
| 409 | — | `qbo/items` | QuickBooks isn't connected. Hide the item dropdown. |
| 4xx/5xx | other/none | any | Show `error.message`. Fall back to `HTTP <status>`. |

---

## 11. Screen → endpoint map

| Screen / action | Calls |
|---|---|
| **Estimates list** | `GET /quotes?status=`, `GET /companies/connections`, `GET /companies/connections/zt/jobs?q=` |
| New estimate (blank / from job) | `POST /quotes` |
| Reopen from list | `POST /quotes/:id/reopen` |
| **Quote detail: open** | `GET /quotes/:id` |
| Chat: send / answer card | `POST /quotes/:id/messages` |
| Chat: mic | `POST /voice/transcribe`, then `POST /quotes/:id/messages` |
| Chat: camera / gallery | `POST /quotes/:id/images` |
| **Estimate tab: load** | `GET /companies/connections/qbo/items`, `GET /companies/connections`, `GET /quotes/:id/images` |
| Customer picker | `GET /companies/qbo/customers?q=`, `POST /companies/qbo/customers`, `PATCH /quotes/:id {customerId}` |
| Markup | `PATCH /quotes/:id {markupPercent}` |
| Tax rate | `GET /companies/sales-tax`, `PATCH /quotes/:id {salesTaxId}` |
| Add line | `POST /quotes/:id/items`, then `GET /quotes/:id` |
| Edit / confirm / resolve line | `PATCH /quotes/:id/items/:itemId` |
| Auto-price unmatched lines | `POST /quotes/:id/items/:itemId/price` ×N, then `GET /quotes/:id` |
| Remove line | `DELETE /quotes/:id/items/:itemId` |
| Remove photo | `DELETE /quotes/:id/images/:imageId` |
| Mark as completed | `POST /quotes/:id/complete` |
| Move back to Draft | `POST /quotes/:id/reopen` |
| **Send / download (any state)** | `GET /quotes/:id/email-draft` + `GET /quotes/:id/proposal-pdf`, `POST /quotes/:id/email`, `GET /quotes/:id/proposal-docx`, `GET /quotes/:id/docx` |
| Sync (COMPLETED) | `POST /quotes/:id/qbo`, then `GET /quotes/:id`; `POST /quotes/:id/zt` |

---

## 12. Mobile build checklist

- [ ] Copy the types from `quotesService.ts` / `connectionsService.ts` (or a shared contract
      file) into the app. Don't retype them from this document.
- [ ] One HTTP wrapper: base URL, headers (§2.2), envelope unwrapping, `ApiError` carrying
      `code` + `options`, single-flight 401 refresh.
- [ ] Per-quote write queue (rule 3 in §1).
- [ ] Per-call timeouts (§2.5), especially the agent turn and the price search.
- [ ] Chat: optimistic echo + rollback, answer-echo hiding, block renderer, batched question-card
      answers.
- [ ] Voice: record → base64 → `/voice/transcribe` with the recorder's real mime type.
- [ ] Photos: RN `FormData` `{ uri, name, type }` under `images`. Replace the list with the
      response.
- [ ] Estimate tab driven entirely by the server `Quote`. No client-side money math.
- [ ] Flags table with unknown-flag-is-blocking. Complete gated on `blockingFlagCount`.
- [ ] Auto price search for `unmatched` lines, with a final reconcile.
- [ ] Complete flow handling `OPTION_CHOICE_REQUIRED` and `TAX_RATE_UNAVAILABLE`.
- [ ] Binary downloads to app storage + share sheet. Filename from `Content-Disposition`.
- [ ] Hide integration features when `/companies/connections` fails or isn't connected.

---

## 13. Not yet confirmed against the server

These come from reading the client, not the server source. Check them with copilot-server
before relying on them:

- Exact HTTP status codes for DRAFT-only violations and `TAX_RATE_UNAVAILABLE` (the client only
  branches on `error.code`).
- The full set of block kinds the **estimate** chat's AI messages can carry. Markdown and
  questions are known to be used. Render the others with the shared Copilot block renderer, or
  ignore them.
- Upload limits for `/quotes/:id/images` (max files, max size, accepted formats such as HEIC).
- How long the image `url`s last before they expire.
