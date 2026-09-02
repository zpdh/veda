# Frontend Specification – Veda UI

**Source of truth:** `veda-frontend/` implementation (2026-09-02)
**Runtime:** Node.js 20+, modern browsers · **Framework:** React 19 + TypeScript
**Build:** Vite 8 · **Routing:** React Router 7 · **HTTP:** Axios · **Styling:** Tailwind CSS 4 via `@tailwindcss/vite`

## 1. Current structure

```text
src/
├── main.tsx App.tsx index.css
├── core/
│   ├── api/{axios.ts,constants.ts}
│   ├── components/{AppLayout,Header,Footer,ErrorBanner}
│   ├── hooks/useFetch.ts
│   ├── pages/HomePage.tsx
│   ├── types/dto.ts
│   └── utils/format.ts
└── features/
    ├── leaderboard/{components,dtos,hooks,pages,services}
    └── player/{components,dtos,hooks,pages,services}
```

Feature DTOs are kept in `features/*/dtos`; shared DTOs include `ErrorResponse` and `HookResult<T>`. Components are functional React components using hooks. There is no Redux, Zustand, React Context, or authentication state in the current implementation.

## 2. Routing and layout

`App.tsx` uses `BrowserRouter` and nested routes:

| Route | Component | Layout |
|---|---|---|
| `/` | `HomePage` | standalone |
| `/leaderboards` | `LeaderboardPage` | `AppLayout` |
| `/players` | `SearchPlayerPage` | `AppLayout` |
| `/players/:playerName` | `PlayerPage` | `AppLayout` |

`AppLayout` renders `Header`, an `Outlet` inside the main content area, and `Footer`. Routes are not lazy-loaded.

## 3. API client and fetching

`core/api/axios.ts` creates an Axios instance with `baseURL: import.meta.env.VITE_API_URL` and JSON content type. It has no interceptors, auth injection, or centralized error mapper. `core/api/constants.ts` supplies the relative route `api/v1`.

`useFetch<T>` accepts an abort-aware fetch function and dependency list, returns `{data, loading, error}`, aborts on unmount/dependency change, ignores cancellation, and maps Axios response bodies directly to `ErrorResponse`. Unknown failures become `ERR_UNKNOWN`.

## 4. Leaderboard feature

`LeaderboardPage` loads `GET api/v1/leaderboards`, maps returned `leaderboards[].leaderboardName` into `LeaderboardSelector`, selects the name through the `name` query parameter, then loads `GET api/v1/leaderboards/{name}`. `SnapshotTable` renders `EntryRow` values and the page displays `fetchedAt` using `formatISODate`.

Current leaderboard DTOs:

```ts
interface EntryOut { entryId: number; rank: number; playerName: string; value: number }
interface SnapshotResponse { snapshotId: number; leaderboardName: string; fetchedAt: string; entries: EntryOut[] }
interface LeaderboardOut { leaderboardId: string; leaderboardName: string; estimatedTimePerCompletionMinutes: number }
interface LeaderboardsResponse { leaderboards: LeaderboardOut[] }
```

There is currently no `SnapshotForm`, create-snapshot hook/service, or frontend POST implementation. The backend ingestion API is therefore producer-facing rather than exposed by this UI.

## 5. Player feature

`SearchPlayerPage` fetches `GET api/v1/players/`, supplies names to `SearchBar`, and navigates to `/players/:playerName`. `PlayerPage` fetches `GET api/v1/players/{playerName}`, sorts entries by rank, and renders `PlayerOverviewCard`, `PlayerRankingRow`, and `PlaytimeDistributionCard`.

```ts
interface AllPlayerNamesResponse { players: string[] }
interface PlayerEntryOut {
  leaderboardName: string; rank: number; value: number;
  estimatedPlaytimeMinutes: number;
}
interface PlayerResponse {
  username: string; totalCompletions: number; totalPlaytimeMinutes: number;
  entries: PlayerEntryOut[];
}
```

Player names are URL-encoded when submitted from `PlayerPage`; `SearchPlayerPage` currently navigates with the raw selected name. Server validation remains authoritative.

## 6. Styling and assets

Tailwind CSS 4 is registered as a Vite plugin. Global styles are in `src/index.css` and `src/styles/tailwind.css`; the UI uses Veda-specific utility classes and bundled assets under `src/assets` (backgrounds, icons, favicon, and clock graphic). Inter is provided by `@fontsource-variable/inter`.

## 7. Scripts and validation

From `veda-frontend/`:

- `npm run dev` starts Vite.
- `npm run lint` runs Oxlint.
- `npm run build` runs `tsc -b` and `vite build`.
- `npm run preview` serves the production build.

The package currently has no test script and does not include Jest, React Testing Library, Cypress, MSW, or axe tooling. Coverage and E2E claims in earlier specs are planned work, not current capabilities.

## 8. Security and known limitations

React escapes rendered text. The API client sends JSON and currently has no auth behavior. The backend’s snapshot Bearer secret must not be placed in browser code; ingestion should remain a trusted producer/server concern. Add explicit URL encoding in all navigation/service paths and a centralized Axios error policy if API error handling expands.
