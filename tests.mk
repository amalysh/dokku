DOKKU_SSH_PORT ?= 22
DOKKU_DOMAIN ?= dokku.me
GO_PLUGINS := $(shell sh -c 'find plugins -type f -name "go.mod" -exec dirname "{}" \; | sort -u | sed -e "s/$$/\/.../" | xargs')
SYSTEM := $(shell sh -c 'uname -s 2>/dev/null')

bats:
ifeq ($(SYSTEM),Darwin)
ifneq ($(shell bats --version >/dev/null 2>&1 ; echo $$?),0)
	brew install bats-core
endif
else
	git clone https://github.com/bats-core/bats-core.git /tmp/bats
	cd /tmp/bats && sudo ./install.sh /usr/local
	rm -rf /tmp/bats
endif

shellcheck:
ifneq ($(shell shellcheck --version >/dev/null 2>&1; echo $$?),0)
ifeq ($(SYSTEM),Darwin)
	brew install shellcheck
else
	sudo apt-get update -qq && sudo apt-get -qq -y --no-install-recommends install shellcheck
endif
endif

shfmt:
ifneq ($(shell shfmt --version >/dev/null 2>&1; echo $$?),0)
ifeq ($(shfmt),Darwin)
	brew install shfmt
else
	wget -qO /tmp/shfmt https://github.com/mvdan/sh/releases/download/v3.5.1/shfmt_v3.5.1_linux_${TARGETARCH}
	chmod +x /tmp/shfmt
	sudo mv /tmp/shfmt /usr/local/bin/shfmt
endif
endif

xmlstarlet:
ifneq ($(shell xmlstarlet --version >/dev/null 2>&1 ; echo $$?),0)
ifeq ($(SYSTEM),Darwin)
	brew install xmlstarlet
else
	sudo apt-get update -qq && sudo apt-get -qq -y --no-install-recommends install xmlstarlet
endif
endif

ci-dependencies: bats shellcheck xmlstarlet docker-apt-repo

docker-apt-repo:
ifdef INSTALL_DOCKER_REPO
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /usr/share/keyrings/docker.gpg
	echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(shell . /etc/os-release && echo "$$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
	sudo apt update
	sudo apt-get -qq -y --no-install-recommends install docker-buildx-plugin docker-compose-plugin
endif

setup-deploy-tests:
ifdef ENABLE_DOKKU_TRACE
	echo "-----> Enable dokku trace"
	dokku trace:on
endif
	@echo "Setting $(DOKKU_DOMAIN) in /etc/hosts"
	sudo /bin/bash -c "[[ `ping -c1 $(DOKKU_DOMAIN) >/dev/null 2>&1; echo $$?` -eq 0 ]] || echo \"127.0.0.1  $(DOKKU_DOMAIN) *.$(DOKKU_DOMAIN) www.test.app.$(DOKKU_DOMAIN)\" >> /etc/hosts"

	@echo "-----> Generating keypair..."
	mkdir -p /root/.ssh
	rm -f /root/.ssh/dokku_test_rsa*
	echo -e  "y\n" | ssh-keygen -f /root/.ssh/dokku_test_rsa -t rsa -N ''
	chmod 700 /root/.ssh
	chmod 600 /root/.ssh/dokku_test_rsa
	chmod 644 /root/.ssh/dokku_test_rsa.pub

	@echo "-----> Setting up ssh config..."
ifneq ($(shell ls /root/.ssh/config >/dev/null 2>&1 ; echo $$?),0)
	echo "Host $(DOKKU_DOMAIN) \\r\\n Port $(DOKKU_SSH_PORT) \\r\\n RequestTTY yes \\r\\n IdentityFile /root/.ssh/dokku_test_rsa" >> /root/.ssh/config
	echo "Host 127.0.0.1 \\r\\n Port 22333 \\r\\n RequestTTY yes \\r\\n IdentityFile /root/.ssh/dokku_test_rsa" >> /root/.ssh/config
else ifeq ($(shell grep $(DOKKU_DOMAIN) /root/.ssh/config),)
	echo "Host $(DOKKU_DOMAIN) \\r\\n Port $(DOKKU_SSH_PORT) \\r\\n RequestTTY yes \\r\\n IdentityFile /root/.ssh/dokku_test_rsa" >> /root/.ssh/config
	echo "Host 127.0.0.1 \\r\\n Port 22333 \\r\\n RequestTTY yes \\r\\n IdentityFile /root/.ssh/dokku_test_rsa" >> /root/.ssh/config
else
	sed --in-place 's/Port 22 \r/Port $(DOKKU_SSH_PORT) \r/g' /root/.ssh/config
	cat /root/.ssh/config
endif

ifneq ($(wildcard /etc/ssh/sshd_config),)
	sed --in-place "s/^#Port 22$\/Port 22/g" /etc/ssh/sshd_config
ifeq ($(shell grep 22333 /etc/ssh/sshd_config),)
	sed --in-place "s:^Port 22:Port 22 \\nPort 22333:g" /etc/ssh/sshd_config
endif
ifeq ($(shell grep 22333 /usr/lib/systemd/system/ssh.socket),)
	sed --in-place "s:^ListenStream=22:ListenStream=22 \\nListenStream=22333:g" /usr/lib/systemd/system/ssh.socket
endif
	systemctl daemon-reload || true
	systemctl restart ssh.socket || service ssh restart
endif

	@echo "-----> Installing SSH public key..."
	echo "" > /home/dokku/.ssh/authorized_keys
	sudo sshcommand acl-remove dokku test
	cat /root/.ssh/dokku_test_rsa.pub | sudo sshcommand acl-add dokku test
	chmod 700 /home/dokku/.ssh
	chmod 600 /home/dokku/.ssh/authorized_keys

ifeq ($(shell grep $(DOKKU_DOMAIN) /home/dokku/VHOST 2>/dev/null),)
	@echo "-----> Setting default VHOST to $(DOKKU_DOMAIN)..."
	echo "$(DOKKU_DOMAIN)" > /home/dokku/VHOST
endif
ifeq ($(DOKKU_SSH_PORT), 22)
	$(MAKE) prime-ssh-known-hosts
endif

setup-docker-deploy-tests: setup-deploy-tests
ifdef ENABLE_DOKKU_TRACE
	echo "-----> Enable dokku trace"
	docker exec dokku bash -c "dokku trace:on"
endif
	docker exec dokku bash -c "sshcommand acl-remove dokku test"
	docker exec dokku bash -c "echo `cat /root/.ssh/dokku_test_rsa.pub` | sshcommand acl-add dokku test"
	$(MAKE) prime-ssh-known-hosts

prime-ssh-known-hosts:
	@echo "-----> Intitial SSH connection to populate known_hosts..."
	@echo "=====> SSH $(DOKKU_DOMAIN)"
	ssh -o StrictHostKeyChecking=no dokku@$(DOKKU_DOMAIN) help
	@echo "=====> SSH 127.0.0.1"
	ssh -o StrictHostKeyChecking=no dokku@127.0.0.1 help

lint-setup:
	@mkdir -p test-results/shellcheck tmp/shellcheck
	@find . -not -path '*/\.*' -not -path './debian/*' -not -path './docs/*' -not -path './tests/*' -not -path './vendor/*' -type f | xargs file | grep text | awk -F ':' '{ print $$1 }' | xargs head -n1 | grep -B1 "bash" | grep "==>" | awk '{ print $$2 }' > tmp/shellcheck/test-files
	@cat .shellcheckrc | sed -n -e '/^# SC/p' | cut -d' ' -f2 | paste -d, -s > tmp/shellcheck/exclude

lint-ci: lint-setup
	# these are disabled due to their expansive existence in the codebase. we should clean it up though
	@cat .shellcheckrc | sed -n -e '/^# SC/p'
	@echo linting...
	@cat tmp/shellcheck/test-files | xargs shellcheck | tests/shellcheck-to-junit --output test-results/shellcheck/results.xml --files tmp/shellcheck/test-files --exclude $(shell cat tmp/shellcheck/exclude)

lint-golang:
	golangci-lint run $(GO_PLUGINS)

lint-shfmt: shfmt
	# verifying via shfmt
	# shfmt -l -bn -ci -i 2 -d .
	@shfmt -l -bn -ci -i 2 -d .

lint: lint-shfmt lint-ci

ci-go-coverage:
	@$(MAKE) ci-go-coverage-plugin PLUGIN_NAME=common
	@$(MAKE) ci-go-coverage-plugin PLUGIN_NAME=config
	@$(MAKE) ci-go-coverage-plugin PLUGIN_NAME=network

ci-go-coverage-plugin:
	mkdir -p test-results/coverage
	docker run --rm \
		-e DOKKU_ROOT=/home/dokku \
		-e CODACY_TOKEN=$$CODACY_TOKEN \
		-e CIRCLE_SHA1=$$CIRCLE_SHA1 \
		-e GO111MODULE=on \
		-v $$PWD:$(GO_REPO_ROOT) \
		-w $(GO_REPO_ROOT) \
		$(BUILD_IMAGE) \
		bash -c "cd plugins/$(PLUGIN_NAME) && \
			echo 'installing gomega' && \
			go get github.com/onsi/gomega && \
			echo 'installing godacov' && \
			go get github.com/schrej/godacov && \
			echo 'installing goverage' && \
			go get github.com/haya14busa/goverage && \
			go install github.com/haya14busa/goverage && \
			echo 'running goverage' && \
			goverage -v -coverprofile=./../../test-results/coverage/$(PLUGIN_NAME).out && \
			echo 'running godacov' && \
			(godacov -r ./../../test-results/coverage/$(PLUGIN_NAME).out -c $$CIRCLE_SHA1 -t $$CODACY_TOKEN || true)" || exit $$?

go-tests:
	@$(MAKE) go-test-plugin PLUGIN_NAME=common
	@$(MAKE) go-test-plugin PLUGIN_NAME=config
	@$(MAKE) go-test-plugin PLUGIN_NAME=network

go-test-plugin:
	cd plugins/$(PLUGIN_NAME) && go get github.com/onsi/gomega && DOKKU_ROOT=/home/dokku go test -v -p 1 -race -mod=readonly || exit $$?

go-test-plugin-in-docker:
	@echo running go unit tests...
	docker run --rm \
		-e GO111MODULE=on \
		-v $$PWD:$(GO_REPO_ROOT) \
		-w $(GO_REPO_ROOT) \
		$(BUILD_IMAGE) \
		bash -c "make go-test-plugin PLUGIN_NAME=$(PLUGIN_NAME)" || exit $$?

unit-tests: go-tests
	@echo running bats unit tests...
ifndef UNIT_TEST_BATCH
	@$(QUIET) bats tests/unit
else
	@$(QUIET) ./tests/ci/unit_test_runner.sh $$UNIT_TEST_BATCH
endif

deploy-test-go-fail-predeploy:
	@echo deploying go-fail-predeploy app...
	cd tests && ./test_deploy ./apps/go-fail-predeploy $(DOKKU_DOMAIN) '' true

deploy-test-go-fail-postdeploy:
	@echo deploying go-fail-postdeploy app...
	cd tests && ./test_deploy ./apps/go-fail-postdeploy $(DOKKU_DOMAIN) '' true

deploy-test-checks-root:
	@echo deploying checks-root app...
	cd tests && ./test_deploy ./apps/checks-root $(DOKKU_DOMAIN) '' true

deploy-test-main-branch:
	@echo deploying checks-root app to main branch...
	cd tests && ./test_deploy ./apps/checks-root $(DOKKU_DOMAIN) '' true main

deploy-test-clojure:
	@echo deploying config app...
	cd tests && ./test_deploy ./apps/clojure $(DOKKU_DOMAIN)

deploy-test-config:
	@echo deploying config app...
	cd tests && ./test_deploy ./apps/config $(DOKKU_DOMAIN)

deploy-test-dockerfile:
	@echo deploying dockerfile app...
	cd tests && ./test_deploy ./apps/dockerfile $(DOKKU_DOMAIN)

deploy-test-dockerfile-noexpose:
	@echo deploying dockerfile-noexpose app...
	cd tests && ./test_deploy ./apps/dockerfile-noexpose $(DOKKU_DOMAIN)

deploy-test-dockerfile-procfile:
	@echo deploying dockerfile-procfile app...
	cd tests && ./test_deploy ./apps/dockerfile-procfile $(DOKKU_DOMAIN)

deploy-test-gitsubmodules:
	@echo deploying gitsubmodules app...
	cd tests && ./test_deploy ./apps/gitsubmodules $(DOKKU_DOMAIN)

deploy-test-go:
	@echo deploying go app...
	cd tests && ./test_deploy ./apps/go $(DOKKU_DOMAIN)

deploy-test-java:
	@echo deploying java app...
	cd tests && ./test_deploy ./apps/java $(DOKKU_DOMAIN)

deploy-test-multi:
	@echo deploying multi app...
	cd tests && ./test_deploy ./apps/multi $(DOKKU_DOMAIN)

deploy-test-nodejs-express:
	@echo deploying nodejs-express app...
	cd tests && ./test_deploy ./apps/nodejs-express $(DOKKU_DOMAIN)

deploy-test-nodejs-express-noprocfile:
	@echo deploying nodejs-express app with no Procfile...
	cd tests && ./test_deploy ./apps/nodejs-express-noprocfile $(DOKKU_DOMAIN)

deploy-test-nodejs-worker:
	@echo deploying nodejs-worker app...
	cd tests && ./test_deploy ./apps/nodejs-worker $(DOKKU_DOMAIN)

deploy-test-php:
	@echo deploying php app...
	cd tests && ./test_deploy ./apps/php $(DOKKU_DOMAIN)

deploy-test-python-flask:
	@echo deploying python-flask app...
	cd tests && ./test_deploy ./apps/python-flask $(DOKKU_DOMAIN)

deploy-test-ruby:
	@echo deploying ruby app...
	cd tests && ./test_deploy ./apps/ruby $(DOKKU_DOMAIN)

deploy-test-scala:
	@echo deploying scala app...
	cd tests && ./test_deploy ./apps/scala $(DOKKU_DOMAIN)

deploy-test-static:
	@echo deploying static app...
	cd tests && ./test_deploy ./apps/static $(DOKKU_DOMAIN)

deploy-tests:
	@echo running deploy tests...
	@$(QUIET) $(MAKE) deploy-test-checks-root
	@$(QUIET) $(MAKE) deploy-test-main-branch
	@$(QUIET) $(MAKE) deploy-test-go-fail-predeploy
	@$(QUIET) $(MAKE) deploy-test-go-fail-postdeploy
	@$(QUIET) $(MAKE) deploy-test-config
	@$(QUIET) $(MAKE) deploy-test-clojure
	@$(QUIET) $(MAKE) deploy-test-dockerfile
	@$(QUIET) $(MAKE) deploy-test-dockerfile-noexpose
	@$(QUIET) $(MAKE) deploy-test-dockerfile-procfile
	@$(QUIET) $(MAKE) deploy-test-gitsubmodules
	@$(QUIET) $(MAKE) deploy-test-go
	@$(QUIET) $(MAKE) deploy-test-java
	@$(QUIET) $(MAKE) deploy-test-multi
	@$(QUIET) $(MAKE) deploy-test-nodejs-express
	@$(QUIET) $(MAKE) deploy-test-nodejs-express-noprocfile
	@$(QUIET) $(MAKE) deploy-test-nodejs-worker
	@$(QUIET) $(MAKE) deploy-test-php
	@$(QUIET) $(MAKE) deploy-test-python-flask
	@$(QUIET) $(MAKE) deploy-test-scala
	@$(QUIET) $(MAKE) deploy-test-static

test: setup-deploy-tests lint unit-tests deploy-tests

test-ci:
	@mkdir -p test-results/bats
	@cd tests/unit && echo "executing tests: $(shell cd tests/unit ; circleci tests glob *.bats | circleci tests split --split-by=timings --timings-type=classname | xargs)"
	cd tests/unit && bats --report-formatter junit --timing -o ../../test-results/bats $(shell cd tests/unit ; circleci tests glob *.bats | circleci tests split --split-by=timings --timings-type=classname | xargs)

tests-ci-retry-failed:
	wget -qO /tmp/bats-retry.tgz https://github.com/josegonzalez/go-bats-retry/releases/download/v0.2.1/bats-retry_0.2.1_linux_x86_64.tgz
	tar xzf /tmp/bats-retry.tgz -C /usr/local/bin
	bats-retry --execute test-results/bats

test-ci-docker: setup-docker-deploy-tests deploy-test-checks-root deploy-test-config deploy-test-multi deploy-test-go-fail-predeploy deploy-test-go-fail-postdeploy

generate-ssl-tars: generate-ssl-tar generate-ssl-sans-tar generate-ssl-wildcard-tar

generate-ssl-tar:
	rm -rf /tmp/dokku-server_ssl
	mkdir -p /tmp/dokku-server_ssl
	openssl req -x509 -newkey rsa:4096 -sha256 -nodes -keyout /tmp/dokku-server_ssl/server.key          -out /tmp/dokku-server_ssl/server.crt -subj "/CN=$(DOKKU_DOMAIN)" -days 3650
	rm tests/unit/server_ssl.tar
	cd /tmp/dokku-server_ssl && tar cvf $(PWD)/tests/unit/server_ssl.tar server.key server.crt
	tar -tvf tests/unit/server_ssl.tar

generate-ssl-sans-tar:
	rm -rf /tmp/dokku-server_ssl_sans
	mkdir -p /tmp/dokku-server_ssl_sans
	openssl req -x509 -newkey rsa:4096 -sha256 -nodes -keyout /tmp/dokku-server_ssl_sans/server.key     -out /tmp/dokku-server_ssl_sans/server.crt -subj "/CN=test.$(DOKKU_DOMAIN)" -days 3650 -addext "subjectAltName = DNS:www.test.$(DOKKU_DOMAIN), DNS:www.test.app.$(DOKKU_DOMAIN)"
	rm tests/unit/server_ssl_sans.tar
	cd /tmp/dokku-server_ssl_sans && tar cvf $(PWD)/tests/unit/server_ssl_sans.tar server.key server.crt
	tar -tvf tests/unit/server_ssl_sans.tar

generate-ssl-wildcard-tar:
	rm -rf /tmp/dokku-server_ssl_wildcard
	mkdir -p /tmp/dokku-server_ssl_wildcard
	openssl req -x509 -newkey rsa:4096 -sha256 -nodes -keyout /tmp/dokku-server_ssl_wildcard/server.key -out /tmp/dokku-server_ssl_wildcard/server.crt -subj "/CN=*.$(DOKKU_DOMAIN)" -days 3650
	rm tests/unit/server_ssl_wildcard.tar
	cd /tmp/dokku-server_ssl_wildcard && tar cvf $(PWD)/tests/unit/server_ssl_wildcard.tar server.key server.crt
	tar -tvf tests/unit/server_ssl_wildcard.tar
