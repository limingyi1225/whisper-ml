FROM node:22-alpine

ENV NODE_ENV=production
# The relay defaults to loopback so an unproxied `npm start` cannot expose an endpoint
# backed by a real OpenAI key. In a container loopback is useless, so opt in here.
ENV HOST=0.0.0.0
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src

USER node
EXPOSE 8787
CMD ["node", "src/index.js"]
