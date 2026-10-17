# Design

A native menu-bar utility with a compact window. Status, Stop/Resume, the agent cursor switch, permission setup, connections (with the app each agent is working in), CLI setup, and diagnostics should be directly accessible. Use platform typography, semantic colors, standard controls, and concise actionable messages.

The development UI is implemented but has not received visual acceptance. Do not display internal backend names in ordinary product controls. Third-party notices remain available in distribution resources.

Agent cursors: each agent's pointer is the Phosphor navigation arrow from the app icon, tinted with the agent's color (blue, purple, orange, green, pink, teal by order), with a white outline, a small name tag in the same color, a two-point highlight around the target window, and a ripple where a click lands. Pointer moves glide over about a quarter second. While the agent thinks between calls, pointer and name tag bounce gently; while a call runs there is no extra motion, since the glides and ripples show the work. The menu-bar list shows each agent's color as a dot. The app icon is an Icon Composer document (`assets/icon/`): Airpoint's dark tile and blue ripples with that pointer clicking at their center.
