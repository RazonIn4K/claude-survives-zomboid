// Test-process clock only. The real bridge has no clock override setting.
const fs = require('node:fs');
const originalNow = Date.now;
Date.now = () => originalNow() + Number(fs.readFileSync(process.env.PZ_TEST_CLOCK_FILE, 'utf8'));
