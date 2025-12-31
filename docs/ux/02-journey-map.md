# Top Journeys

| Journey | Goal | Entry | Steps | Expected | Failure modes | Emotional risk |
| --- | --- | --- | --- | --- | --- | --- |
| Onboarding | Load catalog + set token | Launch app | Paste token → Test token → Choose region | Token validated, UI ready | Missing catalog, bad token | Confusion about readiness |
| Explore endpoint | Submit API call | Home | Pick group/path/method → Fill params → Submit | 2xx response, formatted view | Validation errors, auth failure | “Did it send?” |
| Save favorite | Reuse request | Home | Configure request → Save Favorite → Replay | Favorite visible + loads form | Empty name, not persisted | Fear of losing setup |
| Inspect response | Deep dive | Response tab | Toggle raw/pretty → Inspect result → Export | Inspector shows tree, export succeeds | Large payload freeze, copy fails | Doubt about completeness |
| Conversation report | Run report | Ops Insights tab | Enter ConversationId → Run report → Inspect/export | Timeline + insights rendered | Missing ID/token, slow jobs | Waiting without progress |
| Job watch | Track async job | Job Watch tab | Poll job → Export results | Status updated, file saved | 404/failed job | “Is it stuck?” |
| Templates | Use predefined payloads | Templates tab | Load template → Submit | Pre-filled fields, success | Template missing values | Anxiety about wrong IDs |

Responsive checkpoints: smallest width still shows selectors; focus order works for keyboard; debug HUD optional for devs.
