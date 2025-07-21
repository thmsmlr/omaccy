# Omaccy

A small collection of macOS automations powered by [Hammerspoon](https://www.hammerspoon.org/) plus a minimal static webpage for GitHub Pages.

## 🌟 Inspiration

This project was inspired by [DHH's Omarchy project](https://world.hey.com/dhh/omarchy-bottling-that-inspiration-before-it-spoils-cd75e26b), which aims to create a beautiful, preconfigured Arch Linux + Hyprland setup. While Omarchy focuses on Linux, Omaccy brings similar automation principles to macOS using Hammerspoon. Both projects share the goal of bottling up configuration and automation to make life easier for others.


## 🚀 Installation

```bash
# Clone the repository
$ git clone https://github.com/thmsmlr/omaccy.git
$ cd omaccy

# Run the installer (will prompt for sudo if Homebrew needs it)
$ ./install.sh
```

The installer will:

1. Ensure you have Homebrew available (required if Hammerspoon needs to be installed).
2. Install the Hammerspoon app via Homebrew if you do not already have it.
3. Symlink this repo's `hammerspoon/` directory to `~/.hammerspoon`, backing up any existing config.

Once complete, launch the Hammerspoon app and press <kbd>⌘</kbd><kbd>R</kbd> (or use the provided hotkey <kbd>⌘⌃⌥R</kbd>) to reload the configuration.

## 🌐 GitHub Pages

A minimal `index.html` lives in the project root so you can enable **GitHub Pages** (Settings → Pages) and serve it directly from the `main` branch.

## 📄 License

[MIT](LICENSE) 









- [x] focusDirection 

stop window watcher
find window left or right, focus it, bring to view, add to window stack
resume window watcher

- [x] goToSpace

stop window watcher
lookup last focused window on space, focus it, bring to view, add to window stack
resume window watcher

- [x] launchApp

stop window watcher
catalog all windows *** need a reliable method given Chrome's weirdness with PWAs
launch app (via menu, or by command)
catalog all windows
find the new window
add to window stack to the right of the last focused window
resume window watcher

- [x] closeApp

stop window watcher
close window
if app's last window, close app
shift focus to the left if exists, otherwise focus the last window on the stack
resume window watcher



# Window Watcher

## Window Focused

add to window stack
focus window

## Window Created

position new window to the right of the last focused window
focus window



### Unimplemented functionality

- [ ] A reliable way to enumerate all the windows given Chrome launching fucking with hs.window.filter (for use all over the place)

    This is a big one. A test case is to launch ChatGPT on a new space when it's already open on another space.
    This fucks with the windows in a deterministic way that we can use as a test case.

- [ ] Snapshotting windows and diffing them to find the new window (for use in launchApp)

Issues trying to resolve:

- ChatGPT PWA and Chrome more generally rapidly creates new windows and destroys them on launchApp via command.

This'll work because launchApp will pause the window watcher and only resume it after all the windows have settled.
Once the windows have settled, we can retile the space based on their locations, since we'll know the new window, we
can ensure it's to the right of the last focused window.
The window stack will be preserved since the window watcher will have been paused.


- Switching spaces can fuck with the window stack because it's not deterministic which window it'll focus because Chrome is weird.

This'll work because goToSpace will pause the window watcher and only resume after the focus and space jitter settles.
Once settled, we will have the last focused window on the space, and we can focus it.
the window stack will be preserved since the window watcher will have been paused.

- Click Focusing a window will properly add it to Window Stack.

Since we're still listening for window focus events (when not paused) the click to change focus will properly add it to the window stack.

- Launching apps outside of Omaccy will properly add it to the window stack.

Since we're still listening for window creation events which are more reliable when not launching via command (Spotlight, File > New Window, etc.) they will be picked up and added to the window stack and positioned to the right of the last focused window.
