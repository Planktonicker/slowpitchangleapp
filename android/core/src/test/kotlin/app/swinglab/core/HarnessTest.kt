// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

package app.swinglab.core

import kotlin.test.Test
import kotlin.test.assertEquals

/** The harness can find and read the shared fixtures at all. */
class HarnessTest {
    @Test
    fun fixturesNameTheSameSourceOfTruth() {
        assertEquals(Core.SOURCE_OF_TRUTH, Fixtures.root.s("_source_of_truth"))
    }
}
