
To build a [MirageOS](https://mirage.io) unikernel with [nix](https://nixos.org):
```
$ git clone <...>/<unikernel-name>.git
$ cd <unikernel-name>
$ nix flake new . -t github:/RyanGibb/hillingar
$ sed -i 's/throw "Put the unikernel name here"/"<unikernel-name>"/g' flake.nix
$ nix build .#<target>
```

