{
  description = "SocialPath - track usernames across social media platforms";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkPython = pkgs:
        let
          ps = pkgs.python3Packages;

          # Not packaged in nixpkgs.
          celery-progress = ps.buildPythonPackage rec {
            pname = "celery-progress";
            version = "0.5";
            pyproject = true;
            src = pkgs.fetchPypi {
              pname = "celery_progress";
              inherit version;
              sha256 = "ca345b8c86c35f6deb32a4b0df9a984f3f5aa9248a152eace9e04363367e848a";
            };
            build-system = [ ps.setuptools ];
            doCheck = false;
          };
        in
        pkgs.python3.withPackages (p: [
          p.beautifulsoup4
          p.celery
          p.django
          p.praw
          p.redis
          p.requests
          p.tweepy
          celery-progress
        ]);

      tolerantLoop = "        try:\n            functions_dict[i](name)\n        except Exception as e:\n            print('SocialPath: %s check failed: %r' % (i, e))";

      # The project's source, patched for the current Django / Tweepy.
      mkApp = pkgs: pkgs.stdenvNoCC.mkDerivation {
        pname = "socialpath-app";
        version = "unstable-2021-01-26";
        src = self;
        dontBuild = true;

        postPatch = ''
          # jsonfield was removed from nixpkgs; Django ships its own JSONField.
          # It stores a missing value as SQL NULL, so the columns must allow it.
          substituteInPlace social/models.py \
            --replace-fail "from jsonfield import JSONField" "from django.db.models import JSONField" \
            --replace-fail "JSONField(blank=True" "JSONField(blank=True, null=True" \
            --replace-fail "default={}" "default=dict"
          # Silence the models.W042 warnings (Django 3.2+).
          echo "DEFAULT_AUTO_FIELD = 'django.db.models.AutoField'" >> socialpath/settings.py
          # django.conf.urls.url was removed in Django 4.
          substituteInPlace social/urls.py \
            --replace-fail "from django.conf.urls import url" "from django.urls import re_path as url"
          # HttpRequest.is_ajax() was removed in Django 4.
          substituteInPlace social/views.py \
            --replace-fail "request.is_ajax()" "request.headers.get('x-requested-with') == 'XMLHttpRequest'"
          # Tweepy 4 takes keyword arguments; and one failing platform
          # (missing API keys, dead endpoint) must not abort the others.
          substituteInPlace socialpath/tasks.py \
            --replace-fail "api.get_user(username)" "api.get_user(screen_name=username)" \
            --replace-fail "api.search_users(username)" "api.search_users(q=username)" \
            --replace-fail "        functions_dict[i](name)" ${pkgs.lib.escapeShellArg tolerantLoop}
        '';

        installPhase = ''
          mkdir -p $out/share/socialpath
          cp -r backend manage.py social socialpath $out/share/socialpath/
        '';
      };

      mkSocialPath = pkgs:
        let
          app = mkApp pkgs;
          python = mkPython pkgs;
        in
        pkgs.writeShellApplication {
          name = "socialpath";
          runtimeInputs = [ python pkgs.redis pkgs.coreutils ];
          text = ''
            # SocialPath writes its database, keys and CSVs relative to its
            # working directory, so run it from a writable copy.
            data="''${SOCIALPATH_HOME:-''${XDG_DATA_HOME:-$HOME/.local/share}/socialpath}"
            port="''${SOCIALPATH_PORT:-8000}"
            keys="$data/backend/keys.json"
            mkdir -p "$data/redis"
            cd "$data"

            # Refresh the code on upgrade; keep keys.json, db.sqlite3 and results.
            if [ "$(cat .installed-from 2>/dev/null || true)" != "${app}" ]; then
              if [ -f "$keys" ]; then cp "$keys" keys.json.keep; fi
              cp -rT --no-preserve=mode,ownership "${app}/share/socialpath" "$data"
              if [ -f keys.json.keep ]; then mv keys.json.keep "$keys"; fi
              echo "${app}" > .installed-from
            fi
            chmod 600 "$keys"

            trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM

            if ! redis-cli -p 6379 ping >/dev/null 2>&1; then
              redis-server --bind 127.0.0.1 --port 6379 --dir "$data/redis" \
                --save "" --appendonly no > redis/redis.log &
              until redis-cli -p 6379 ping >/dev/null 2>&1; do sleep 0.2; done
            fi

            python manage.py makemigrations social
            python manage.py migrate
            python -m celery --app socialpath worker --loglevel=info --concurrency=2 &

            echo
            echo "SocialPath: http://127.0.0.1:$port/search/"
            echo "API keys:   $keys (restart after editing)"
            echo "Press Ctrl+C to stop."
            echo
            python manage.py runserver --noreload "127.0.0.1:$port" &
            wait "$!"
          '';
          meta = {
            description = "Track usernames across social media platforms";
            homepage = "https://github.com/woj-ciech/SocialPath";
            license = pkgs.lib.licenses.mit;
            mainProgram = "socialpath";
          };
        };
    in
    {
      packages = forAllSystems (pkgs: {
        default = mkSocialPath pkgs;
        socialpath = mkSocialPath pkgs;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${pkgs.system}.default;
        };
      });

      # Django system checks, migrations and a celery import, all offline.
      checks = forAllSystems (pkgs: {
        django = pkgs.runCommand "socialpath-django-check" {
          nativeBuildInputs = [ (mkPython pkgs) ];
        } ''
          cp -r --no-preserve=mode ${mkApp pkgs}/share/socialpath app
          cd app
          python manage.py check
          python manage.py makemigrations social
          python manage.py migrate
          python -c "import django, os; os.environ['DJANGO_SETTINGS_MODULE']='socialpath.settings'; django.setup(); import socialpath.tasks, celery_progress.backend; from socialpath.celery import app; print(app)"
          touch $out
        '';
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell { packages = [ (mkPython pkgs) pkgs.redis ]; };
      });
    };
}
