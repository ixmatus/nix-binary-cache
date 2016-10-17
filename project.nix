{ pkgs, haskellPackages, }:

let
  pname = "nix-binary-cache";
  version = "0.0.1";
  # Haskell packages the library depends on (in addition to above). We
  # use names here because for some reason some of these are null in
  # the haskell package set, but still work as dependencies...
  dependencies = [
    "aeson"
    "aeson-compat"
    "attoparsec"
    "base"
    "bytestring"
    "classy-prelude"
    "directory"
    "http-client"
    "http-media"
    "http-types"
    "mtl"
    "servant-client"
    "servant-server"
    "servant"
    "text"
    "transformers"
    "wai"
    "wai-extra"
    "warp"
  ];

  # Haskell packages the tests depend on (in addition to above).
  testDependencies = [
    "QuickCheck"
    "hspec"
  ];

  # Names of extensions that the library uses.
  extensions = [
    "ConstraintKinds"
    "CPP"
    "DataKinds"
    "DeriveGeneric"
    "FlexibleContexts"
    "FlexibleInstances"
    "GADTs"
    "GeneralizedNewtypeDeriving"
    "LambdaCase"
    "MultiParamTypeClasses"
    "NoImplicitPrelude"
    "OverloadedStrings"
    "QuasiQuotes"
    "RecordWildCards"
    "ScopedTypeVariables"
    "TypeFamilies"
    "TypeOperators"
    "TypeSynonymInstances"
    "ViewPatterns"
  ];

  # Derivations needed to use in the nix shell.
  shellRequires = with pkgs; [
    curl
    nix.out
    less
    nmap
    silver-searcher
    which
  ];

  toHaskellPkgs = map (pname: haskellPackages."${pname}");

  inherit (builtins) compareVersions;
  inherit (pkgs.lib) filter concatStringsSep isDerivation optional;
  joinLines = builtins.concatStringsSep "\n";
  joinCommas = builtins.concatStringsSep ", ";
  joinSpaces = builtins.concatStringsSep " ";

  # Options for ghc when both testing and building the library.
  ghc-options = [
    # Warn on everything, including tabs.
    "-Wall" "-fwarn-tabs"
    # Don't warn on unused do-binding.
    "-fno-warn-unused-do-bind"
    # Don't warn on name shadowing. This is why lexical scoping exists...
    "-fno-warn-name-shadowing"
    # Enable threading.
    "-threaded" "-rtsopts" "-with-rtsopts=-N"
  ];

  # Options for ghc when just building the library.
  ghc-build-options = ghc-options ++ [
    # Enable optimization
    "-O3"
    # Turn warnings into errors.
    "-Werror"
  ];

  # Options for ghc when just testing.
  ghc-test-options = ghc-options;

  # Inspect the servant derivation to see if it's an old version; if
  # so define a cpp flag.
  cpp-options = optional
    (compareVersions haskellPackages.servant.version "0.7" < 0)
    "-DOLD_SERVANT";

  # .ghci file text.
  dotGhci = pkgs.writeText "${pname}.ghci" (joinLines (
    map (ext: ":set -X${ext}") extensions ++
    [
      ":set prompt \"\\ESC[34mλ> \\ESC[m\""
      "import Data.Text (Text)"
      "import qualified Data.Text as T"
      "import qualified Data.Text.Encoding as T"
      ""
    ]
  ));

  # Cabal file text.
  cabalFile = pkgs.writeText "${pname}.cabal" ''
    -- This cabal file is generated by a nix expression (see project.nix).
    -- It is not meant to be modified by hand.
    name:                ${pname}
    version:             ${version}
    license:             MIT
    license-file:        LICENSE
    author:              Allen Nelson
    maintainer:          ithinkican@gmail.com
    build-type:          Simple
    cabal-version:       >=1.10
    data-files:            sql/tables.sql

    -- Define the executable
    executable nix-client
      main-is:             Nix/Cache/Client/Main.hs
      build-depends:       ${joinCommas dependencies}
      hs-source-dirs:      src
      default-language:    Haskell2010
      default-extensions:  ${joinCommas extensions}
      ghc-options:         -O3 ${joinSpaces ghc-build-options}

    ${if true then "" else ''
    executable nix-server
      main-is:             Server.hs
      build-depends:       ${joinCommas dependencies}
      hs-source-dirs:      src
      default-language:    Haskell2010
      default-extensions:  ${joinCommas extensions}
      ghc-options:         -O3 ${joinSpaces ghc-build-options}
    ''}

    -- Define a unit test suite
    test-suite unit-tests
      type:                exitcode-stdio-1.0
      hs-source-dirs:      src, tests
      main-is:             Unit.hs
      build-depends:       ${joinCommas (dependencies ++ testDependencies)}
      ghc-options:         ${joinSpaces ghc-test-options}
      cpp-options:         -DUNIT_TESTS ${joinSpaces cpp-options}
      default-language:    Haskell2010
      default-extensions:  ${joinCommas extensions}
  '';
in

haskellPackages.mkDerivation rec {
  inherit pname version;
  src = let
    inherit (builtins) filterSource all match;
    # It'd be nice to make this a whitelist, but filterSource is kind
    # of terrible.
    blacklist = map (r: "^${r}$") [
      "${pname}\\.cabal" "init_db\\.sh" ".*\\.nix" "dist"
      "\\.git" "#.*" "\\.#.*" ".*~" "\\.ghci" "\\.gitignore"
    ];
    check = path: _:
      all (regex: match regex (baseNameOf path) == null) blacklist;
  in filterSource check ./.;
  isExecutable = true;
  buildTools = [haskellPackages.cabal-install];
  testHaskellDepends = toHaskellPkgs testDependencies;
  testDepends = shellRequires;
  checkPhase = ''
    export HOME=$TMPDIR USER=$(whoami)
    dist/build/unit-tests/unit-tests
  '';
  libraryHaskellDepends = toHaskellPkgs dependencies;
  executableHaskellDepends = toHaskellPkgs dependencies;
  preConfigure = ''
    cp -f ${cabalFile} ${pname}.cabal
  '';
  shellHook = ''
    # Alias for entering REPL for unit tests.
    alias testr='cabal repl unit-tests'

    # Define a function which uses ghci to run unit tests.
    runtests() { echo ':main' | testr; }

    # Make sure we're in the project directory, and do initialization.
    if [[ -e project.nix ]] && grep -q ${pname} project.nix; then
      cp -f ${dotGhci} .ghci
      eval "${preConfigure}"
      cabal configure --enable-tests
    fi
  '';
  description = "A web server";
  license = pkgs.lib.licenses.unfree;
}
