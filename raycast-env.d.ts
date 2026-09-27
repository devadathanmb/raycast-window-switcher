/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Show Minimized Windows - Show minimized (hidden) windows in the list */
  "showMinimizedWindows": boolean,
  /** Show Applications Without Visible Windows - Show windows belonging to applications hidden with macOS's Hide Application action */
  "showApplicationsWithoutVisibleWindows": boolean
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `window-switcher` command */
  export type WindowSwitcher = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `window-switcher` command */
  export type WindowSwitcher = {}
}

