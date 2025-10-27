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

