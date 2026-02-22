# Calendar Block Manipulation Rules

## Overview

The dashboard calendar allows users to create, move, resize, and delete time blocks. These rules prevent gaming of focus scores and earned browse minutes by restricting manipulation of blocks based on their temporal state.

## Block States

| State | Definition | Criteria |
|-------|-----------|----------|
| **Past** | Block has ended | `blockEndMinute <= currentMinuteOfDay` |
| **Active** | Block is in progress | `blockStartMinute <= currentMinuteOfDay < blockEndMinute` |
| **Future** | Block hasn't started | `blockStartMinute > currentMinuteOfDay` |

## Permissions Matrix

| Operation | Past | Active | Future |
|-----------|------|--------|--------|
| Move (drag) | No | No | Yes |
| Resize start | No | No | Yes |
| Resize end | No | Yes (shorten or extend) | Yes |
| Edit start time | No | No | Yes |
| Edit end time | No | Yes | Yes |
| Delete | No | No | Yes* |
| Edit title | Yes | Yes | Yes |
| Edit description | Yes | Yes | Yes |
| View assessments | Yes | Yes | Yes |

*With confirmation dialog if assessment data exists for the block.

## Key Design Decision: Active Blocks Can Be Shortened

An active block's end time CAN be moved earlier (to end the block early) or later (to extend it). This lets users adjust their plan mid-block without gaming past scores. However, the start time is locked because the block has already been recording assessments from that point.

## Visual Treatment

- **Past blocks**: 50% opacity, no resize handles, default cursor, no hover highlight
- **Active blocks**: Indigo border glow, only bottom resize handle visible
- **Future blocks**: Normal appearance (existing styles)

## Validation (Dashboard-Side)

### Overlap Checking
All time changes (drag, resize, editor) must check `hasBlockOverlap()` before applying. The block editor currently does NOT do this -- must be added to `saveBlockEdit()`.

### Minimum Duration
All blocks must be at least 15 minutes. Drag/resize already enforces this. The block editor must add this check.

## Validation (Swift-Side)

`handleSetScheduleFromDashboard()` in MainWindow.swift should validate:
1. No overlapping blocks
2. All blocks have `endTime > startTime`
3. All blocks are at least 15 minutes
4. Past blocks match the previously persisted schedule (detect client-side bypass)

For MVP, client-side enforcement is sufficient. Swift validation is a safety net for a future release.

## Implementation Files

| File | Changes |
|------|---------|
| `dashboard.html` (JS) | Add `isBlockPast/Active/Future()` helpers, guard drag/resize/editor, add `.past`/`.active` classes, add overlap check to editor |
| `dashboard.html` (CSS) | Add `.calendar-block.past` and `.calendar-block.active` styles |
| `MainWindow.swift` | (Future) Add validation to `handleSetScheduleFromDashboard()` |

## Refresh Strategy

Block state classes must refresh as time passes (a block transitions from active to past). Tie into the existing `renderNowLine()` 60-second interval to also re-apply `.past`/`.active` classes via `renderCalendarBlocks()` or a lighter class-update pass.
