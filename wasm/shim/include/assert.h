/* Freestanding `assert` for the WASM build.
 *
 * The browser/WASM module is compiled without a libc, so libyaml's
 * `assert` calls have nowhere to go. They check internal invariants only,
 * so the release build drops them (the same choice `NDEBUG` makes).
 */
#ifndef ZAML_SHIM_ASSERT_H
#define ZAML_SHIM_ASSERT_H

#define assert(cond) ((void)0)

#endif /* ZAML_SHIM_ASSERT_H */
