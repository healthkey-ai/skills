---
name: hk-frontend-review
description: "[v1.0.0] React/Tailwind/shadcn/React Query review. Catches anti-patterns, stale closures, cache misses, accessibility gaps, and shadcn misuse."
metadata:
  version: "1.0.0"
  source: "healthkey"
---

# Frontend Review

## Preamble

```bash
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
echo "BRANCH: $BRANCH"

BASE="main"
if git rev-parse --verify origin/main >/dev/null 2>&1; then
  BASE="main"
elif git rev-parse --verify origin/master >/dev/null 2>&1; then
  BASE="master"
fi
echo "BASE: $BASE"

DIFF_STAT=$(git diff "$BASE"..."$BRANCH" --stat -- '*.tsx' '*.ts' '*.css' 2>/dev/null || echo "")
if [ -z "$DIFF_STAT" ]; then
  echo "NO_DIFF: true"
else
  echo "NO_DIFF: false"
  echo "$DIFF_STAT"
fi

FILES_CHANGED=$(git diff "$BASE"..."$BRANCH" --name-only -- '*.tsx' '*.ts' '*.css' 2>/dev/null | wc -l | tr -d ' ')
echo "FILES_CHANGED: $FILES_CHANGED"
```

If `NO_DIFF` is `true`, tell the user there are no frontend changes to review and stop.

## Input

The user may specify:
- A PR number (e.g., `/frontend-review #42`) — fetch with `gh pr diff 42 -- '*.tsx' '*.ts' '*.css'`
- A file or directory (e.g., `/frontend-review src/federation/`) — scope the review to that path
- Nothing — review all frontend changes on the current branch against BASE

## How This Review Works

Three phases. Phase 1 gathers context, Phase 2 runs two parallel review agents, Phase 3 merges and reports.

### Phase 1: Gather Context

Read these in parallel:

1. **The diff**: `git diff $BASE...$BRANCH -- '*.tsx' '*.ts' '*.css'` (or scoped to the user's path)
2. **CLAUDE.md**: Read the project's CLAUDE.md for conventions and architecture
3. **Recent commits**: `git log $BASE..$BRANCH --oneline` for commit intent
4. **Package versions**: Read `package.json` for React, React Query, Tailwind, and shadcn versions

### Phase 2: Two-Pass Review (parallel subagents)

Launch TWO agents in parallel:

**Agent A — Structured Best Practices Review**

Prompt the agent with the full diff and project context. It reviews against this checklist:

```
REACT COMPONENT PATTERNS
- [ ] Components have a single responsibility — no god components doing data fetching, state management, and rendering
- [ ] Props interfaces are minimal — no prop drilling through 3+ levels (use context or composition instead)
- [ ] No inline object/array/function literals in JSX props that create new references every render (causes child re-renders)
- [ ] Event handlers that need arguments use useCallback or are stable references, not `onClick={() => fn(x)}` in lists
- [ ] No derived state stored in useState — values computable from props/other state should use useMemo or compute inline
- [ ] useState initializer functions used for expensive initial values: `useState(() => compute())` not `useState(compute())`
- [ ] Conditional hooks: no hooks called inside if/else/loops/early returns (Rules of Hooks)
- [ ] Key props on list items are stable and unique (not array index unless list is static and never reordered)
- [ ] No state updates during render (setting state unconditionally in component body)
- [ ] useEffect dependencies are correct — no missing deps, no unnecessary deps causing infinite loops
- [ ] useEffect cleanup functions provided where needed (event listeners, subscriptions, timers, AbortController)
- [ ] No useEffect for derived state — if you can compute it from existing state/props, do it during render
- [ ] Refs used for values that don't need re-render (previous values, DOM nodes, mutable flags)
- [ ] React.memo used only where profiling shows re-render cost — not sprinkled preventively
- [ ] forwardRef used when component needs to expose a DOM node to parent
- [ ] Error boundaries around sections that can fail independently (data-driven content, third-party widgets)
- [ ] Suspense boundaries with meaningful fallbacks (not just spinner everywhere)
- [ ] Controlled vs uncontrolled inputs are consistent — no mixing ref-based reads with onChange state

STALE CLOSURES & MEMOIZATION
- [ ] useCallback/useMemo dependency arrays include all referenced values from the enclosing scope
- [ ] No stale closure in event handlers — handlers reference current state, not captured-at-mount values
- [ ] setTimeout/setInterval callbacks don't read stale state — use refs or functional setState: `setState(prev => ...)`
- [ ] useMemo used for genuinely expensive computations or referential stability — not for trivial derived values
- [ ] useCallback used when the callback is passed to memoized children or used in useEffect deps — not everywhere

REACT QUERY (TANSTACK QUERY)
- [ ] Query keys are deterministic and include all variables the query depends on
- [ ] Query keys follow a consistent hierarchy: `["domain", "entity", ...params]`
- [ ] No manual cache invalidation where queryClient.setQueryData could be used for optimistic updates
- [ ] Mutations use onSuccess/onSettled to invalidate related queries, not refetchQueries with broad keys
- [ ] placeholderData (keepPreviousData) used for paginated queries to prevent flash of loading state
- [ ] enabled option used to conditionally skip queries (not `if (!ready) return` before useQuery)
- [ ] staleTime set appropriately — not relying on default 0 which refetches on every mount
- [ ] gcTime (cacheTime) considered for data that should persist across unmounts
- [ ] refetchInterval only used for data that genuinely changes server-side (polling) — not as a workaround for stale data
- [ ] Error handling: either global error handler or per-query onError/useErrorBoundary — errors aren't silently swallowed
- [ ] No waterfall queries — parallel fetches use useQueries or multiple useQuery calls (not sequential awaits in useEffect)
- [ ] Mutation loading states shown in UI (isPending check on buttons, forms disabled during submit)
- [ ] queryClient.invalidateQueries uses specific keys — not broad `["labs"]` that triggers unnecessary refetches
- [ ] No duplicate queries — same data fetched by multiple components should share a query key, not make separate requests
- [ ] select option used to transform/filter query data rather than useMemo on query.data
- [ ] Infinite queries (useInfiniteQuery) preferred over manual page-tracking for infinite scroll UIs

TAILWIND CSS
- [ ] No conflicting utility classes on the same element (e.g., `p-4 p-6`, `text-sm text-lg`)
- [ ] Responsive design uses mobile-first: base classes for mobile, sm:/md:/lg: for larger breakpoints
- [ ] Dark mode classes present where needed (if dark mode is supported)
- [ ] No magic numbers in arbitrary values `[37px]` — use spacing scale or define in theme
- [ ] Consistent spacing scale usage — not mixing `gap-3` and `gap-[13px]` arbitrarily
- [ ] Layout uses flex/grid appropriately — no absolute positioning hacks for things flex/grid solve
- [ ] Truncation handled properly: `truncate` or `line-clamp-N` with appropriate `min-w-0` on flex children
- [ ] Interactive elements have visible focus styles (focus-visible:ring-* or similar)
- [ ] Hover/active/disabled states defined for all interactive elements
- [ ] Transitions on interactive state changes (hover, focus) use `transition-colors` or `transition-all` — not jarring
- [ ] No Tailwind classes that duplicate what a shadcn component already provides (e.g., manually styling a button when Button component exists)
- [ ] Color usage follows the design token system — no raw hex/rgb values, use `text-foreground`, `bg-muted`, etc.
- [ ] `sr-only` used for screen-reader text where visual icons need labels
- [ ] Max-width containers used for content readability — no full-width text blocks
- [ ] Spacing is consistent within a component — not mixing `space-y-2` and `space-y-4` without reason

SHADCN/UI USAGE
- [ ] Using shadcn primitives (Button, Card, Dialog, Select, etc.) instead of hand-rolling equivalent HTML
- [ ] Variant props used correctly — Button variant matches semantic intent (destructive for delete, ghost for tertiary)
- [ ] Dialog/Sheet uses controlled open state with onOpenChange (not manual click-outside handling)
- [ ] Select component used instead of native <select> for consistency
- [ ] Form components (Input, Label, Textarea) used with proper labeling — no unlabeled inputs
- [ ] Card used for content grouping with consistent CardHeader/CardContent/CardFooter structure
- [ ] Separator used between sections instead of border-t hacks
- [ ] Badge used for status indicators instead of custom styled spans (unless design differs significantly)
- [ ] Toast/Sonner used for transient feedback instead of alert() or custom notification divs
- [ ] Tooltip used for icon-only buttons and truncated text
- [ ] DropdownMenu used for action menus instead of custom popovers with click-outside handlers
- [ ] No overriding shadcn component styles with inline styles or extra classes that fight the component's design
- [ ] asChild pattern used correctly when composing shadcn components with custom elements

ACCESSIBILITY (a11y)
- [ ] All images have alt text (empty alt="" for decorative images)
- [ ] Icon-only buttons have aria-label
- [ ] Form inputs have associated labels (htmlFor/id or wrapping <label>)
- [ ] Focus management: modals trap focus, return focus on close
- [ ] ARIA roles used correctly — no role="button" on a div when a <button> would work
- [ ] Color contrast meets WCAG AA (4.5:1 for normal text, 3:1 for large text)
- [ ] Loading states announced to screen readers (aria-live="polite" or role="status")
- [ ] Error messages linked to inputs with aria-describedby
- [ ] Skip navigation link for keyboard users (if applicable)
- [ ] No keyboard traps — every interactive element reachable and escapable via keyboard
- [ ] Proper heading hierarchy (h1 > h2 > h3, no skipped levels within a section)
- [ ] aria-hidden="true" on decorative icons so screen readers skip them
- [ ] Tables have proper th/scope for data tables (not div grids pretending to be tables)
- [ ] Dynamic content changes use aria-live regions where appropriate

TYPESCRIPT
- [ ] No `any` types — use `unknown` for truly unknown data, narrow with type guards
- [ ] Union types preferred over enums for string literals
- [ ] Props interfaces defined at the component level, not exported globally unless reused
- [ ] Generic types used where the same pattern repeats with different type parameters
- [ ] Type assertions (`as`) used sparingly — prefer type narrowing with `in`, `instanceof`, or discriminated unions
- [ ] Null checks handled with optional chaining (`?.`) and nullish coalescing (`??`), not `&&` chains
- [ ] Event handler types use React's event types (React.MouseEvent, React.FormEvent) not DOM natives
- [ ] No unused type imports — use `import type` for type-only imports

PERFORMANCE
- [ ] Large lists use virtualization (react-virtual, react-window) — not rendering 1000+ DOM nodes
- [ ] Images lazy-loaded below the fold
- [ ] Heavy components code-split with React.lazy/Suspense
- [ ] No synchronous expensive computation in render path without useMemo
- [ ] Debounced/throttled inputs for search-as-you-type or resize handlers
- [ ] Bundle size: no full lodash import when only one function is needed, no moment.js
- [ ] CSS-only animations preferred over JS-driven animations for simple transitions
- [ ] Avoiding layout thrashing — no reads followed by writes in loops on DOM properties

MODULE FEDERATION SPECIFIC (when reviewing federation/ files)
- [ ] Shared singleton dependencies (React, React Query, Axios) declared in vite.remote.config.ts
- [ ] No direct react-router-dom usage in federation components — navigation via callback props
- [ ] Context providers (LabsProvider) wrap all federation entry points
- [ ] Federation hooks inject apiClient from context — not importing global api instance
- [ ] CSS token contract (--hk-labs-*) used instead of hard-coded colors
- [ ] Components work both standalone and federated — no assumptions about host app
- [ ] No window/document globals that might not exist in SSR host apps
```

The agent returns findings as:

```
FINDING: <short title>
FILE: <path>:<line>
SEVERITY: critical | high | medium | low | nit
CATEGORY: react | react-query | tailwind | shadcn | a11y | typescript | performance | federation
CONFIDENCE: <1-10>
FIXABLE: yes | no
DESCRIPTION: <what's wrong and why it matters>
FIX: <exact code change if fixable, or recommendation if not>
```

**Agent B — Pattern & Consistency Review**

A second agent that reviews for things Agent A's checklist misses:

- Inconsistencies across components (one uses Card, another uses a raw div with the same visual intent)
- Styling patterns that drift (component A uses `text-foreground`, component B uses `text-gray-900` for the same purpose)
- State management inconsistencies (one page uses URL-synced state, another uses useState for the same kind of data)
- React Query cache key collisions or inconsistencies across hooks
- Missing loading/error/empty states (component handles loading but not error, or vice versa)
- Components that should be shared but are duplicated with minor variations
- Prop interfaces that could be simplified (too many boolean flags instead of a variant union)
- Tailwind class ordering inconsistencies (not following the recommended order)
- Shadcn component usage inconsistencies (Button in one place, raw <button> in another for the same visual)
- React patterns that work but have simpler alternatives (useEffect + setState → useMemo, manual fetch → React Query)
- Fragments (<></>) used where a semantic element (section, nav, article) would be appropriate
- Missing TypeScript strictness (non-null assertions `!` where a proper null check should exist)

Same output format as Agent A.

### Phase 3: Merge, Deduplicate, Report

1. **Merge** findings from both agents
2. **Deduplicate** — if both found the same issue, keep the better description
3. **Filter by confidence** — only show findings with confidence >= 5
4. **Sort** by category, then severity (critical first), then confidence (highest first)

#### Fix-First Rules

For each finding, decide: **auto-fix**, **ask**, or **flag**.

**Auto-fix** (do it, show what you did):
- Missing aria-label on icon-only buttons
- Missing aria-hidden="true" on decorative icons
- Tailwind class conflicts (duplicate/contradictory utilities)
- Unused imports and `import type` conversions
- `any` types replaceable with specific types from context
- Missing `key` prop or index-based key on reorderable lists
- Console.log/debugger statements
- Missing disabled state on buttons during mutation isPending
- Inline object literals in JSX that should be hoisted or memoized

**Ask** (present the fix, wait for approval):
- Restructuring components (splitting a large component, extracting hooks)
- Changing state management approach (useState → URL-synced, local → React Query)
- Replacing hand-rolled UI with shadcn components
- Adding React.memo or useCallback (performance changes)
- Changing React Query configuration (staleTime, keys, invalidation strategy)
- Adding error boundaries or Suspense boundaries

**Flag** (report only, no fix offered):
- Architecture observations (this component is getting large)
- Performance concerns that need profiling to confirm
- Accessibility issues that require design input (color contrast, interaction patterns)
- Suggestions that span multiple files and need broader discussion
- Findings with confidence < 7

#### Confidence Calibration

- **9-10**: Definite bug or anti-pattern. Verifiable from the code. (e.g., hook called inside a conditional)
- **7-8**: Very likely an issue. Strong signal. (e.g., missing useCallback causing child re-renders in a list)
- **5-6**: Suspicious but context-dependent. Show it but note uncertainty. (e.g., staleTime might be too aggressive)
- **3-4**: Possible issue, needs investigation. Only show in thorough mode.
- **1-2**: Style preference. Never show.

**Display threshold**: Show findings with confidence >= 5 by default. If user asks for "thorough" review, lower to >= 3.

### Output Format

Present findings grouped by category:

```
## React ({N} findings)

### 1. <title> [severity] [confidence: N/10]
<file:line> — <one-line description>
<what's wrong, why it matters, and fix or recommendation>

## React Query ({N} findings)
...

## Tailwind ({N} findings)
...

## shadcn/ui ({N} findings)
...

## Accessibility ({N} findings)
...

## TypeScript ({N} findings)
...

## Performance ({N} findings)
...

## Federation ({N} findings) (only if federation files changed)
...
```

Within each category, list auto-fixed items first, then items needing approval, then flagged items.

After user approves fixes, apply them all, then show a summary of what changed.

### If Nothing Found

If the review finds zero issues with confidence >= 5, say so clearly:
"Clean diff. No frontend issues found above the confidence threshold. N files reviewed."

Don't manufacture findings to justify the review.

## Project-Specific Context

These are specific to hk-labs and supplement the general checklist:

- **Design token system**: This project uses a dual-layer token system. The standalone app defines tokens in `globals.css` as CSS custom properties. The federation layer maps through `--hk-labs-*` contract tokens in `federation/labs.css`. Always use semantic token classes (`text-foreground`, `bg-muted`, `text-brand-700`, `text-success-700`, etc.) — never raw colors.
- **shadcn/ui customization**: The project uses a customized shadcn setup with the healthkey design system. Components are in `src/components/ui/`. Button has variants: `default`, `primary`, `secondary`, `destructive`, `outline`, `ghost`, `link`. Use the appropriate variant.
- **React Query conventions**: Query keys follow `["labs", "entity", ...params]` pattern defined in `KEYS` object in `src/features/labs/api.ts`. Federation hooks in `src/federation/hooks.ts` are thin wrappers injecting apiClient. Both must stay in sync.
- **Module Federation**: The frontend ships as both standalone Vite app and MF remote. Federation components must not use react-router-dom, must inject apiClient via context, and must use callback props for navigation. CSS must work through the `--hk-labs-*` token contract.
- **Pagination pattern**: URL-synced pagination (useSearchParams) for standalone pages, useState for federation components. Both use the shared `PaginationControls` component and `PageSize` type from `src/lib/pagination.ts`.
- **Shared components**: Reusable lab components live in `src/components/labs/`. Federation and standalone pages both import from here. When reviewing, check that components extracted here don't have router or global-state dependencies.
- **No PHI in client-visible output**: This is a health app. Console.log of lab values, test names, or patient data is a security issue, not just a code quality nit.
