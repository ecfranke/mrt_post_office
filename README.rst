#############
M Post Office
#############

M Post Office is a self-hosted mail administration and webmail platform. It
provides domain and mailbox administration, webmail, calendars, contacts,
Sieve filters, migration tools, auditing and mail-flow statistics through a
modern Vue interface and a Django API.

The project is based on the open-source Modoboa platform. The internal
``modoboa`` Python package and database identifiers are intentionally retained
for extension and migration compatibility; all user-facing branding and new
deployment entry points use **M Post Office**.

Docker deployment
=================

The production stack includes PostgreSQL, Redis, the Django/Gunicorn API, RQ
workers, the scheduler, the built Vue frontend and a Caddy gateway with
automatic HTTPS.

One-click installation on a supported Linux server:

.. code-block:: bash

   sudo bash scripts/install.sh

For unattended installation:

.. code-block:: bash

   sudo bash scripts/install.sh \
     --domain mail.example.com \
     --email ops@example.com \
     --imap-host imap.example.com \
     --smtp-host smtp.example.com \
     --non-interactive

The lower-level deployment workflow remains available:

.. code-block:: bash

   ./scripts/deploy.sh init
   # Edit .env and replace the example domain/mail-server values.
   ./scripts/deploy.sh doctor
   ./scripts/deploy.sh up

See `DEPLOYMENT.md <DEPLOYMENT.md>`_ for the complete Chinese deployment,
upgrade, backup, restore and troubleshooting guide.

Development
===========

The original development-oriented Docker channel remains available:

.. code-block:: bash

   docker compose up --build

It runs Django and Vite development servers and must not be exposed to the
Internet. Production deployments must use ``docker-compose.prod.yml`` through
``scripts/deploy.sh``.

Mail transport boundary
=======================

M Post Office is the administration and webmail application layer. Configure
``IMAP_*`` and ``SMTP_*`` in ``.env`` to connect it to an existing
Postfix/Dovecot installation or a compatible managed mail service. Mailbox
provisioning also requires the transport layer to use M Post Office SQL maps or
the configured ``doveadm`` REST API. The production Compose file deliberately
does not expose SMTP/IMAP ports; running a public mail transport safely also
requires DNS, PTR/rDNS, DKIM, SPF, DMARC, abuse controls and deliverability
monitoring.

License and upstream
====================

This repository retains the upstream ISC license and attribution. Upstream
project: https://github.com/modoboa/modoboa
