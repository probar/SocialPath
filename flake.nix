{
  description = "SocialPath - track usernames across social media platforms";

  # Pinned to a tested nixos-26.05 revision, so no flake.lock is needed.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/7dcdd87373d72e7a2173e4db02e20d3d7f495cfd";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkSocialPath = pkgs:
        let
          inherit (pkgs) lib;

          # Neither package is in nixpkgs 26.05, so build them from PyPI.
          pyPackages = pkgs.python3Packages;

          celery-progress = pyPackages.buildPythonPackage rec {
            pname = "celery-progress";
            version = "0.5";
            pyproject = true;
            src = pkgs.fetchPypi {
              pname = "celery_progress";
              inherit version;
              hash = "sha256-yjRbjIbDX23rMqSw35qYTz9aqSSKFS6s6eBDYzZ+hIo=";
            };
            build-system = [ pyPackages.setuptools pyPackages.wheel ];
            doCheck = false;
          };

          jsonfield = pyPackages.buildPythonPackage rec {
            pname = "jsonfield";
            version = "3.2.0";
            pyproject = true;
            src = pkgs.fetchPypi {
              inherit pname version;
              hash = "sha256-ylOHG8MwiuT0zdw7T5ntXG/Gq7GDL7+0mbxtpWbHDko=";
            };
            build-system = [ pyPackages.setuptools ];
            dependencies = [ pyPackages.django ];
            doCheck = false;
          };

          python = pkgs.python3.withPackages (ps: [
            ps.beautifulsoup4
            ps.celery
            ps.django
            ps.praw
            ps.redis
            ps.requests
            ps.tweepy
            celery-progress
            jsonfield
          ]);

          # One failing platform (no API keys, dead endpoint) must not stop
          # the checks for the remaining platforms.
          tolerantCheck = "        try:\n            functions_dict[i](name)\n        except Exception as error:\n            print('SocialPath: ' + i + ' check failed: ' + repr(error))";

          app = pkgs.stdenvNoCC.mkDerivation {
            pname = "socialpath-app";
            version = "unstable-2021-01-26";
            src = self;
            dontBuild = true;

            # The project dates from 2021: adapt it to Django 5 and Tweepy 4.
            postPatch = ''
              substituteInPlace social/urls.py \
                --replace-fail "from django.conf.urls import url" "from django.urls import re_path as url"
              substituteInPlace social/views.py \
                --replace-fail "request.is_ajax()" "request.headers.get('x-requested-with') == 'XMLHttpRequest'"
              substituteInPlace socialpath/tasks.py \
                --replace-fail "api.get_user(username)" "api.get_user(screen_name=username)" \
                --replace-fail "api.search_users(username)" "api.search_users(q=username)" \
                --replace-fail "        functions_dict[i](name)" ${lib.escapeShellArg tolerantCheck}
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/share/socialpath
              cp -r backend manage.py social socialpath $out/share/socialpath/
              runHook postInstall
            '';
          };
        in
        pkgs.writeShellApplication {
          name = "socialpath";
          runtimeInputs = [ python pkgs.redis pkgs.coreutils ];
          text = ''
            # The app writes its database and CSV files next to its own code,
            # so it runs from a writable copy instead of the read-only Nix store.
            data="''${XDG_DATA_HOME:-$HOME/.local/share}/socialpath"
            keys="$data/backend/keys.json"
            mkdir -p "$data/redis"
            cd "$data"

            if [ "$(cat .installed-from 2>/dev/null || true)" != "${app}" ]; then
              if [ -f "$keys" ]; then cp "$keys" keys.json.keep; fi
              cp -rT --no-preserve=mode,ownership "${app}/share/socialpath" "$data"
              if [ -f keys.json.keep ]; then mv keys.json.keep "$keys"; fi
              echo "${app}" > .installed-from
            fi
            chmod 600 "$keys"

            cleanup() {
              local pids
              pids="$(jobs -p)"
              if [ -n "$pids" ]; then
                # shellcheck disable=SC2086
                kill $pids 2>/dev/null || true
              fi
            }
            trap cleanup EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM

            if ! redis-cli -h 127.0.0.1 -p 6379 ping >/dev/null 2>&1; then
              redis-server --bind 127.0.0.1 --port 6379 --dir "$data/redis" --save "" --appendonly no >redis/redis.log &
              until redis-cli -h 127.0.0.1 -p 6379 ping >/dev/null 2>&1; do sleep 0.2; done
            fi

            python manage.py makemigrations social
            python manage.py migrate
            python -m celery --app socialpath worker --loglevel=info --concurrency=2 &

            echo
            echo "SocialPath: http://127.0.0.1:8000/search/"
            echo "API keys:   $keys (restart after editing)"
            echo "Press Ctrl+C to stop."
            echo
            python manage.py runserver --noreload 127.0.0.1:8000 &
            wait "$!"
          '';
          meta = {
            description = "Track usernames across social media platforms";
            homepage = "https://github.com/woj-ciech/SocialPath";
            license = lib.licenses.mit;
            mainProgram = "socialpath";
          };
        };
    in
    {
      packages = forAllSystems (pkgs: {
        default = mkSocialPath pkgs;
      });
    };
}
