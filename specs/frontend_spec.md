# Frontend Specification – React Application (Veda UI)

**Version:** 1.0
**Target runtime:** Node.js 20+, modern browsers
**Framework:** React 18 (function components & hooks) with TypeScript
**Styling:** Tailwind CSS (utility‑first, configured via `tailwind.config.cjs` & `postcss.config.cjs`)
**State Management:** React Context + `useReducer` for global concerns; local component state for forms. No external Redux unless the app grows substantially.
**Bundler:** Vite (ESBuild) – fast dev server, optimized production builds.
**Routing:** React Router v6 – file‑based route components.
**HTTP client:** Axios (typed) – centralised instance with interceptors for auth & error mapping.
**Testing:** Jest + React Testing Library for unit & hook tests; Cypress for end‑to‑end flows; axe‑core for accessibility.

---

## 1. Architecture Overview
The frontend is a **feature‑oriented modular monolith**. All code lives under `src/` and is grouped by business feature. Cross‑cutting concerns live in `core/`. This mirrors the backend’s modular approach while keeping the SPA lightweight.

### Package layout
```
src/
├─ index.tsx                     # React entry point – renders <App>
├─ App.tsx                       # Root component – providers + router
├─ core/                         # Cross‑cutting utilities
│   ├─ api/                      # Axios instance & interceptors
│   ├─ context/                  # Global contexts (Theme, optional Auth)
│   ├─ hooks/                    # Generic reusable hooks (useFetch, useDebounce)
│   ├─ types/                    # Shared **named records** (ErrorResponse, generic pagination)
│   └─ utils/                    # Misc helpers (format, logger)
├─ features/                     # Feature‑oriented modules
│   └─ leaderboard/              # Leaderboard UI feature
│       ├─ components/            # UI components (LeaderboardList, EntryRow, SnapshotTable, SnapshotForm, ErrorBanner)
│       ├─ pages/                # Page components (DashboardPage, LeaderboardPage)
│       ├─ dto/                  # Feature‑specific **named records** (EntryIn, EntryOut, LeaderboardSnapshotIn, CreateSnapshotRequest, SnapshotResponse, SnapshotCreatedResponse)
│       ├─ hooks/                # Feature‑specific use‑case hooks (useLeaderboardNames, useLatestSnapshot, useCreateSnapshot)
│       └─ services/             # Thin service layer that calls the generic Axios client
├─ assets/                       # Static assets (icons, images)
├─ styles/                       # Global Tailwind imports & resets
└─ tests/                        # Test entry points (unit, integration, e2e)
```

*All components are functional and use React hooks.*

---

## 2. Core / Cross‑Cutting Packages
| Module | Responsibility |
|--------|-----------------|
| `core/api/axios.ts` | Creates a typed Axios instance (`baseURL` from env `VITE_API_URL`), adds request/response interceptors for JWT handling and central error mapping (`ErrorResponse` → UI `ErrorBanner`). |
| `core/context/ThemeContext.tsx` | Provides light/dark theme toggle via React Context. |
| `core/hooks/useFetch.ts` | Generic data‑fetch hook returning `{ data, loading, error }` with automatic abort on component unmount. |
| `core/types/dto.ts` | **Named records** that are truly generic (e.g., `ErrorResponse`) **and the generic hook result interface** (`HookResult<T>`). No feature‑specific DTOs reside here. |
| `core/utils/format.ts` | Helper functions for date/number formatting (`formatISODate`, `formatRank`). |
| `core/utils/logger.ts` | Simple console‑logger wrapper (can be swapped for structured logging). |

---

## 3. Feature – Leaderboard
### 3.1 Pages
* `DashboardPage.tsx` – Landing page with navigation to available leaderboards.
* `LeaderboardPage.tsx` – Shows the latest snapshot for the selected leaderboard and embeds `SnapshotForm` to post new data.

### 3.2 Components
| Component | Description |
|-----------|-------------|
| `LeaderboardList` | Dropdown of all leaderboard names (populated via `useLeaderboardNames`). |
| `EntryRow` | Renders a single entry (`rank`, `playerName`, `value`). |
| `SnapshotTable` | Table displaying `entries` from a `SnapshotResponse`. |
| `SnapshotForm` | Form allowing the user to add multiple `EntryIn` rows and submit a `CreateSnapshotRequest`. Includes client‑side validation (`rank > 0`, `playerName` non‑empty, `value ≥ 0`). |
| `ErrorBanner` | Dismissable banner that shows an `ErrorResponse` from the backend. |

### 3.3 DTOs (`features/leaderboard/dto/`)
```ts
export interface EntryIn {
  rank: number;               // > 0
  playerName: string;        // non‑empty, max 255 chars
  value: number;              // ≥ 0 (number of clears)
}

export interface EntryOut {
  entryId: number;
  rank: number;
  playerName: string;
  value: number;
}

export interface LeaderboardSnapshotIn {
  leaderboardName: string;
  entries: EntryIn[];        // at least one entry, ranks unique (validated in hook)
}

export interface CreateSnapshotRequest {
  snapshots: LeaderboardSnapshotIn[]; // batch – at least one block
}

export interface SnapshotResponse {
  snapshotId: number;
  leaderboardName: string;
  fetchedAt: string;          // ISO‑8601 UTC
  entries: EntryOut[];
}

export interface SnapshotCreatedResponse {
  snapshotIds: number[];
  fetchedAt: string;
  message: string;
}
```
All DTOs are exported from `features/leaderboard/dto/index.ts` for convenient imports.

### 3.4 Use‑Case Hooks (`features/leaderboard/hooks/`)
| Hook | Responsibility |
|------|----------------|
| `useLeaderboardNames()` | Fetches the list of leaderboard names (GET `/v1/api/leaderboards`). Returns a `HookResult<string[]>` object containing `{ data, loading, error }`. |
| `useLatestSnapshot(leaderboardName: string)` | Calls the service `getLatest` and returns `{ data: SnapshotResponse | null, loading, error }`. Handles mapping of backend `ErrorResponse` to UI‑ready error objects. |
| `useCreateSnapshot()` | Returns a `create(payload: CreateSnapshotRequest)` function that posts via `postSnapshot`, manages loading state, and propagates `ErrorResponse` to the UI. |

These hooks act as **frontend use‑case layer** – they encapsulate business rules (duplicate‑rank validation, atomic batch posting) while keeping components purely presentational.

### 3.5 Services (`features/leaderboard/services/`)
```ts
import api from '@/core/api/axios';
import {
  SnapshotResponse,
  SnapshotCreatedResponse,
  CreateSnapshotRequest,
} from '@/features/leaderboard/dto';

export const getLatest = (name: string) =>
  api.get<SnapshotResponse>(`/leaderboards/${name}`);

export const postSnapshot = (payload: CreateSnapshotRequest) =>
  api.post<SnapshotCreatedResponse>(`/leaderboards/snapshot`, payload);
```
The service layer is thin – it only forwards typed payloads to the generic Axios client.

---

## 4. Routing
`src/App.tsx` uses **React Router v6** with lazy‑loaded feature pages:
```tsx
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { lazy, Suspense } from 'react';

const DashboardPage = lazy(() => import('./features/leaderboard/pages/DashboardPage'));
const LeaderboardPage = lazy(() => import('./features/leaderboard/pages/LeaderboardPage'));

export default function App() {
  return (
    <BrowserRouter>
      <Suspense fallback={<div>Loading…</div>}>
        <Routes>
          <Route path="/" element={<Navigate to="/leaderboards" replace />} />
          <Route path="/leaderboards" element={<DashboardPage />} />
          <Route path="/leaderboards/:name" element={<LeaderboardPage />} />
          {/* Future routes go here */}
        </Routes>
      </Suspense>
    </BrowserRouter>
  );
}
```
Lazy loading keeps the initial bundle minimal.

---

## 5. State Management
* **Global concerns** (theme, optional auth) are provided via React Context (`core/context`).
* **Local UI state** (form fields, selected leaderboard) lives inside components or feature hooks.
* No Redux or Zustand is introduced at this stage; the architecture can be expanded later without breaking existing code.

---

## 6. Styling
* **Tailwind CSS** is the default – utility classes are applied directly in JSX.
* For rare edge‑case custom CSS you may still create a `*.module.css` file and import it alongside Tailwind utilities.
* Global Tailwind configuration lives in `tailwind.config.cjs`; `styles/tailwind.css` imports the base Tailwind directives.

---

## 7. Testing Strategy
| Layer | Tool | Key assertions |
|-------|------|----------------|
| **Unit / Hook** | Jest + React Testing Library | Verify that each custom hook (`useLeaderboardNames`, `useLatestSnapshot`, `useCreateSnapshot`) returns the correct typed data, handles loading/error correctly, and enforces validation rules (e.g., duplicate ranks). |
| **Component** | Jest + React Testing Library | Snapshot tests for pure UI components (`EntryRow`, `SnapshotTable`, `ErrorBanner`). |
| **Integration / Page** | Jest + React Testing Library + MSW (Mock Service Worker) | Render `LeaderboardPage` and assert that a successful GET populates the table, that validation errors are shown, and that a successful POST triggers the success banner. |
| **End‑to‑End** | Cypress | Simulate a user flow: navigate to a leaderboard, view snapshot, fill the `SnapshotForm`, submit, and verify UI updates and success message. |
| **Accessibility** | axe‑core (via `jest-axe`) | Ensure each page meets WCAG AA criteria. |

**Coverage target:** ≥ 85 % for the `features/leaderboard` bundle.

---

## 8. Build & Deployment
* **Bundler:** Vite – `vite.config.ts` contains the Tailwind plugin and output settings.
* **Production build:** `npm run build` generates an optimized static site in `dist/`.
* **Docker:** Multi‑stage Dockerfile – stage 1 builds the app, stage 2 serves `dist/` via Nginx.
* **CI (GitHub Actions):**
  1. `npm ci` – exact lockfile install.
  2. `npm run lint` – ESLint with TypeScript parser.
  3. `npm run typecheck` – `tsc --noEmit`.
  4. `npm test -- --coverage` – Jest + coverage.
  5. `npm run build` – verify production build.
  6. Optional: Deploy static assets to Netlify/Vercel or push Docker image to a registry.

---

## 9. Security & Validation Checklist
* **Input validation** – Client‑side checks enforce `rank > 0`, non‑empty `playerName`, and `value ≥ 0`. Server‑side validation remains the source of truth.
* **Error handling** – Central Axios interceptor maps backend `ErrorResponse` to a UI `ErrorBanner`.
* **Content Security Policy** – Set via Nginx (`script-src 'self'`, `style-src 'self'` etc.) when serving static assets.
* **XSS protection** – React escapes rendered strings; avoid `dangerouslySetInnerHTML` unless content is sanitized.
* **CSRF** – API is stateless and uses auth headers; CSRF risk is minimal.
* **Dependency audit** – `npm audit` runs in CI and fails on high‑severity findings.

---

## 10. Open Questions / Future Work
* **State‑management scaling** – If the UI grows to many pages or complex filters, evaluate Redux Toolkit, Zustand, or Jotai.
* **Internationalisation** – Add `react-i18next` for multilingual support.
* **Dark‑mode persistence** – Store theme preference in `localStorage` and hydrate on app start.
* **Real‑time updates** – WebSocket or Server‑Sent Events could push snapshot changes to the UI without polling.
* **SSR / SSG** – If SEO or initial‑paint performance becomes critical, consider migrating to Next.js with static generation for the leaderboard list.

---

*Prepared by the Architect – 2026‑08‑11*