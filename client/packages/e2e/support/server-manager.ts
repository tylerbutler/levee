const HEALTH_URL = "http://localhost:4000/health";
const HEALTH_CHECK_TIMEOUT_MS = 5_000;
const HEALTH_CHECK_INTERVAL_MS = 500;

async function checkHealth(): Promise<boolean> {
	try {
		const response = await fetch(HEALTH_URL);
		return response.ok;
	} catch {
		return false;
	}
}

export async function ensureServerRunning(): Promise<void> {
	console.log("Checking if Levee server is running...");

	const startTime = Date.now();
	while (Date.now() - startTime < HEALTH_CHECK_TIMEOUT_MS) {
		if (await checkHealth()) {
			console.log("Levee server is running and healthy");
			return;
		}
		await new Promise((resolve) =>
			setTimeout(resolve, HEALTH_CHECK_INTERVAL_MS),
		);
	}

	throw new Error(
		[
			"Levee server is not running on localhost:4000.",
			"Start it with: just server",
			"(in a separate terminal from the levee repo root)",
		].join("\n"),
	);
}
