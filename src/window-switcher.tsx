import {
  Action,
  ActionPanel,
  closeMainWindow,
  environment,
  getPreferenceValues,
  Icon,
  Keyboard,
  List,
  PopToRootType,
  showToast,
  Toast,
} from '@raycast/api';
import { execFile } from 'child_process';
import { join } from 'path';
import { setTimeout as delay } from 'timers/promises';
import { useCallback, useEffect, useState } from 'react';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

interface WindowInfo {
  processName: string;
  windowTitle: string;
  appPath: string;
  pid: number;
  windowId: number;
  isMinimized: boolean;
  isFullscreen: boolean;
  isAppHidden: boolean;
}

interface BinaryResponse {
  success: boolean;
  error?: string;
}

const BINARY_PATH = join(environment.assetsPath, 'win-ninja');
const HELPER_TIMEOUT_MS = 5_000;
const TRANSITION_REFRESH_DEADLINES_MS = [120, 350, 700];

async function runHelper<T>(args: string[]): Promise<T> {
  const { stdout } = await execFileAsync(BINARY_PATH, args, {
    timeout: HELPER_TIMEOUT_MS,
  });
  const output = stdout.trim();
  if (!output) {
    throw new Error('Window helper returned an empty response');
  }
  return JSON.parse(output) as T;
}

async function getWindows(): Promise<WindowInfo[]> {
  const windows = await runHelper<unknown>(['list']);
  if (!Array.isArray(windows)) {
    throw new Error('Window helper returned an invalid window list');
  }
  return windows as WindowInfo[];
}

async function runAction(args: string[], successMessage: string): Promise<boolean> {
  try {
    const result = await runHelper<BinaryResponse>(args);
    if (!result.success) {
      await showToast({
        style: Toast.Style.Failure,
        title: 'Window action failed',
        message: result.error ?? 'The helper did not provide an error',
      });
      return false;
    }

    await showToast({
      style: Toast.Style.Success,
      title: successMessage,
    });
    return true;
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: 'Window action failed',
      message: error instanceof Error ? error.message : String(error),
    });
    return false;
  }
}

async function focusWindow(window: WindowInfo): Promise<void> {
  try {
    const result = await runHelper<BinaryResponse>([
      'focus',
      String(window.pid),
      String(window.windowId),
    ]);
    if (!result.success) {
      await showToast({
        style: Toast.Style.Failure,
        title: 'Failed to switch windows',
        message: result.error ?? 'The selected window is no longer available',
      });
      return;
    }

    await closeMainWindow({ popToRootType: PopToRootType.Immediate });
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: 'Failed to switch windows',
      message: error instanceof Error ? error.message : String(error),
    });
  }
}

function windowStateSignature(windows: WindowInfo[]): string {
  return JSON.stringify(
    windows
      .map((window): [number, number, string, boolean, boolean, boolean] => [
        window.pid,
        window.windowId,
        window.windowTitle,
        window.isMinimized,
        window.isFullscreen,
        window.isAppHidden,
      ])
      .sort(([leftPid, leftWindowId], [rightPid, rightWindowId]) =>
        leftPid === rightPid ? leftWindowId - rightWindowId : leftPid - rightPid,
      ),
  );
}

export default function SwitchWindows() {
  const [windows, setWindows] = useState<WindowInfo[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const { showMinimizedWindows, showApplicationsWithoutVisibleWindows } =
    getPreferenceValues<Preferences>();

  const filterWindows = useCallback(
    (allWindows: WindowInfo[]) =>
      allWindows.filter(
        (window) =>
          (showMinimizedWindows || !window.isMinimized) &&
          (showApplicationsWithoutVisibleWindows || !window.isAppHidden),
      ),
    [showApplicationsWithoutVisibleWindows, showMinimizedWindows],
  );

  const loadWindows = useCallback(async () => {
    setIsLoading(true);
    try {
      const allWindows = await getWindows();
      setWindows(filterWindows(allWindows));
    } catch (error) {
      console.error('Failed to list windows:', error);
      await showToast({
        style: Toast.Style.Failure,
        title: 'Failed to list windows',
        message: error instanceof Error ? error.message : String(error),
      });
      setWindows([]);
    } finally {
      setIsLoading(false);
    }
  }, [filterWindows]);

  const refreshAfterAction = useCallback(
    async (transitionAware = false) => {
      if (!transitionAware) {
        await loadWindows();
        return;
      }

      setIsLoading(true);
      try {
        let previousSnapshot = '';
        let previousDeadline = 0;
        for (const deadline of TRANSITION_REFRESH_DEADLINES_MS) {
          await delay(deadline - previousDeadline);
          previousDeadline = deadline;

          const allWindows = await getWindows();
          const filtered = filterWindows(allWindows);
          setWindows(filtered);

          const snapshot = windowStateSignature(filtered);
          if (snapshot === previousSnapshot) break;
          previousSnapshot = snapshot;
        }
      } catch (error) {
        console.error('Failed to refresh windows after transition:', error);
        await showToast({
          style: Toast.Style.Failure,
          title: 'Failed to refresh windows',
          message: error instanceof Error ? error.message : String(error),
        });
      } finally {
        setIsLoading(false);
      }
    },
    [filterWindows, loadWindows],
  );

  useEffect(() => {
    loadWindows();
  }, [loadWindows]);

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="Filter by application name or window title..."
    >
      {windows.length === 0 && !isLoading ? (
        <List.EmptyView icon={Icon.Window} title="No open windows found" />
      ) : (
        windows.map((window) => (
          <List.Item
            key={`${window.pid}-${window.windowId}`}
            icon={window.appPath ? { fileIcon: window.appPath } : Icon.Window}
            title={window.windowTitle}
            accessories={[{ text: window.processName }]}
            keywords={[window.processName]}
            actions={
              <ActionPanel>
                <Action
                  title="Switch to Window"
                  icon={Icon.Window}
                  onAction={() => focusWindow(window)}
                />
                {window.isMinimized ? (
                  <Action
                    title="Maximize Window"
                    icon={Icon.ArrowsExpand}
                    shortcut={{ modifiers: ['cmd'], key: 'm' }}
                    onAction={async () => {
                      const succeeded = await runAction(
                        ['maximize', String(window.pid), String(window.windowId)],
                        `Maximized "${window.windowTitle}"`,
                      );
                      if (succeeded) await refreshAfterAction();
                    }}
                  />
                ) : !window.isFullscreen ? (
                  <Action
                    title="Minimize Window"
                    icon={Icon.Minus}
                    shortcut={{ modifiers: ['cmd'], key: 'm' }}
                    onAction={async () => {
                      const succeeded = await runAction(
                        ['minimize', String(window.pid), String(window.windowId)],
                        `Minimized "${window.windowTitle}"`,
                      );
                      if (succeeded) await refreshAfterAction(true);
                    }}
                  />
                ) : null}
                <Action
                  title={window.isFullscreen ? 'Exit Full Screen' : 'Make Full Screen'}
                  icon={window.isFullscreen ? Icon.ArrowsContract : Icon.ArrowsExpand}
                  shortcut={{ modifiers: ['cmd'], key: 'f' }}
                  onAction={async () => {
                    const command = window.isFullscreen ? 'unfullscreen' : 'fullscreen';
                    const successMessage = window.isFullscreen
                      ? `Exited full screen for "${window.windowTitle}"`
                      : `Made "${window.windowTitle}" full screen`;
                    const succeeded = await runAction(
                      [command, String(window.pid), String(window.windowId)],
                      successMessage,
                    );
                    if (succeeded) await refreshAfterAction(true);
                  }}
                />
                <Action
                  title="Close Window"
                  icon={Icon.XMarkCircle}
                  style={Action.Style.Destructive}
                  shortcut={{ modifiers: ['cmd', 'shift'], key: 'w' }}
                  onAction={async () => {
                    const succeeded = await runAction(
                      ['close', String(window.pid), String(window.windowId)],
                      `Closed "${window.windowTitle}"`,
                    );
                    if (succeeded) await refreshAfterAction();
                  }}
                />
                <Action
                  title={window.isAppHidden ? 'Show Application' : 'Hide Application'}
                  icon={window.isAppHidden ? Icon.Eye : Icon.EyeDisabled}
                  shortcut={{ modifiers: ['cmd'], key: 'h' }}
                  onAction={async () => {
                    const command = window.isAppHidden ? 'show-app' : 'hide-app';
                    const successMessage = window.isAppHidden
                      ? `Showed "${window.processName}"`
                      : `Hid "${window.processName}"`;
                    const succeeded = await runAction(
                      [command, String(window.pid)],
                      successMessage,
                    );
                    if (succeeded) await refreshAfterAction();
                  }}
                />
                <Action.CopyToClipboard
                  title="Copy Window Title"
                  content={window.windowTitle}
                  shortcut={Keyboard.Shortcut.Common.Copy}
                />
                <Action
                  title="Refresh Window List"
                  icon={Icon.ArrowClockwise}
                  shortcut={Keyboard.Shortcut.Common.Refresh}
                  onAction={loadWindows}
                />
              </ActionPanel>
            }
          />
        ))
      )}
    </List>
  );
}
