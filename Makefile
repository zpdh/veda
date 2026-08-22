.PHONY: infra-up infra-down backend frontend dev

infra-up:
	cd veda-backend && podman-compose up -d

infra-down:
	cd veda-backend && podman-compose down

backend:
	cd veda-backend && . .venv/bin/activate && uvicorn app.main:app --reload

frontend:
	cd veda-frontend && npm run dev

dev:
	(cd veda-backend && . .venv/bin/activate && uvicorn app.main:app --reload) & \
	(cd veda-frontend && npm run dev) & \
	wait

