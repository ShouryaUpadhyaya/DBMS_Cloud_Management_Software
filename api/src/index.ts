import { createApp } from './app.js';
import { config } from './config.js';
import { closePools } from './db.js';
import { closeStream } from './stream.js';

const server = createApp().listen(config.port, () => console.log(`crms api listening on :${config.port}`));

const shutdown = async () => {
  await closeStream();
  server.close();
  await closePools();
  process.exit(0);
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
