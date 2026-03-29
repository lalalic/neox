# Hydrogen (OpenText Communications) Copilot Instructions

## Project Overview
Hydrogen is a multi-module enterprise CCM (Customer Communications Management) platform with three Angular frontends (Designer, Editor, Console) and a Spring Boot Java backend (Empower server).

## Architecture

### Module Structure
- **designer/** - Angular 21 communications design application
- **editor/** - Angular 21 content authoring application  
- **console/** - Angular 21 admin console application
- **server/** - Spring Boot 3 backend (Empower services)
- **common/** - Shared Angular/TypeScript utilities, UI components, and schemas
- **testFramework/** - Shared Java testing utilities (Selenium, REST Assured)

### Technology Stack
- **Frontend**: Angular 21 (standalone components), TypeScript, RxJS, Material Design, UX Aspects Universal
- **Backend**: Java 11+, Spring Boot 3, Hibernate, Liquibase
- **Testing**: Jasmine/Karma (frontend), TestNG (backend)

## Coding Conventions

### Angular Patterns
1. **Standalone Components**: Project is migrating to Angular standalone components. New components MUST use `imports: [...]` instead of `NgModule` declarations.
2. **Dependency Injection**: Use `providedIn: 'root'` for services or `providers: [...]` in component decorators.
3. **Product Differentiation**: The `PRODUCT` enum (from `common/PRODUCT.ts`) is compile-time replaced to enable editor vs designer differences:
   ```typescript
   if (PRODUCT.IS_DESIGNER) { /* designer-specific logic */ }
   if (PRODUCT.IS_EMPOWER) { /* editor-specific logic */ }
   ```

### Common Module Organization
- **common/unsorted/** - Shared services, utilities, and legacy components
- **common/ui/** - Reusable UI components (buttons, tooltips, info bubbles)
- **common/data/** - Shared data structures and TypeScript models
- **common/content-area/** - Content editing core components
- **Schema Types**: `CasSchema`, `DasSchema`, `EISchema`, `EEPSchema`, `CSSchema` in `common/unsorted/schema/`

### Naming Conventions
- **Components**: PascalCase with descriptive suffixes (e.g., `EditDomainPanelComponent`, `OutputReviewWidget`)
- **Services**: PascalCase ending in `Service` (e.g., `DasService`, `ModalDialogService`)
- **Files**: kebab-case for Angular files (`.component.ts`, `.service.ts`, `.scss`)
- **Structures**: PascalCase ending in `Structure` for data models (e.g., `ApplicationStructure`, `DataSetStructure`)

### Testing Patterns
- **Frontend**: Jasmine with data-driven tests using `jasmine-data_driven_tests`
- **Backend**: TestNG with REST Assured for API tests, Selenium for E2E
- **Mocks**: Centralized in `designer/web/testSpecs/mocks/` (e.g., `MockDasService`, `MockTooltipDirectiveModule`)
- Use `ComponentFixture`, `TestBed.configureTestingModule()`, and harnesses from `@angular/cdk/testing`

## Key Files Reference

- [common/boot-config.js](../common/boot-config.js) - Frontend initialization and locale loading
- [common/PRODUCT.ts](../common/PRODUCT.ts) - Compile-time product type constants for editor vs designer differences
- [common/unsorted/schema/](../common/unsorted/schema/) - TypeScript schemas: `CasSchema`, `DasSchema`, `EISchema`, `EEPSchema`, `CSSchema`
- [designer/web/app/designservice/das.service.ts](../designer/web/app/designservice/das.service.ts) - Main Design Asset Store service

## Integration Points

- **DasService** - Main service for Design Asset Store API calls
- **REST APIs** - Backend exposes RESTful services under `/empower/api/...`
- **WebSocket** - Real-time updates via STOMP using `@stomp/rx-stomp`
- **Schema Contracts** - Use TypeScript schemas (`CasSchema`, `DasSchema`, etc.) for API type safety

## TypeScript & JavaScript Best Practices

### General Coding

- **Avoid setTimeout()**: Should not be used unless explicitly required for timing (e.g., hiding UI after delay). Never use as a workaround for async/event ordering issues. It adds asynchronicity that makes code less responsive, harder to debug, and can cause race conditions.

- **Use const enums**: TypeScript enumerations should be constant for better performance (inlined during compilation):
  ```typescript
  export const enum MyConstantEnum {
      ONE = 1,
      TWO = 2,
      THREE = 3
  }
  ```
  For heavy template usage, create a non-constant companion:
  ```typescript
  export const MyConstantEnumValues = {
      ONE: MyConstantEnum.ONE,
      TWO: MyConstantEnum.TWO,
      THREE: MyConstantEnum.THREE
  }
  ```

- **Avoid TypeScript namespaces**: They negatively impact minification and runtime performance.

- **Use const for locals**: Prefer `const` for local variables that are never reassigned (never use `var`).

- **Use readonly for class fields**: Apply to class fields that never change.

- **Readonly arrays**: Array types should be readonly when possible to prevent accidental mutation and improve API clarity.

- **Avoid deep member accesses**: Minifier cannot minify member names. Assign objects within member access chains to local variables, especially for `MESSAGES` object:
  ```typescript
  // Instead of repeating MESSAGES.DESIGNER.ERRORS.SOME_ERROR
  const errors = MESSAGES.DESIGNER.ERRORS;
  ```

- **Prefer for-of loops**: Use instead of `Array.forEach()` for better performance and control-flow flexibility.

- **Parallel async operations**: Never use `await` in a for loop. Make network calls in parallel using `Promise.all()`, not serially.

- **Class inheritance with barrel files**: Export/import inheritance chains spanning multiple files from barrel files to prevent circular dependencies (see `IHasParentBarrelFile.ts`, `UserCommandBarrelFile.ts`).

- **Separate UI state from data models**: Temporary client session state should not be stored in DAS JSON objects. Store UI state (e.g., accordion expanded) separately from `DasSchema.Resource` objects.

## Angular Best Practices

### Components

- **Standalone components**: All new components/directives/pipes should be standalone. Transition product to be module-less.

- **Dependency injection via inject()**: Use `inject()` method instead of constructor injection:
  - Avoids passing services up constructor chain in inheritance
  - Removes oddity of referring to values using types
  - Aligns with `useDefineForClassFields` option

- **ViewChild/ViewChildren**: Always access HTML elements with ViewChild/ViewChildren annotations, never use `document.getElementById()` or similar native selectors.

- **OnPush change detection**: Recommended for simple components with primitive inputs (strings, numbers, booleans). Tricky with reference types—use Immer if needed.

- **markForCheck() over detectChanges()**: Use `ChangeDetectorRef.markForCheck()` instead of `detectChanges()`. Only needed for OnPush components.

- **Careful with ngOnChanges()**: Called very frequently, can impact performance. Consider using setters for individual inputs instead. Avoid using to clear cached state.

- **Unidirectional data flow**: Data flow from component class to template must remain unidirectional. Breaking this causes `ExpressionChangedAfterItHasBeenCheckedError`.

- **Required inputs**: Use `{ required: true }` for non-optional component inputs.

- **Built-in control flow**: Use Angular's built-in control flow syntax instead of deprecated `ngIf`, `ngFor`, `ngSwitch` directives.

### Templates

- **Direct MESSAGES access**: Avoid `exsTranslate` pipe for better performance:
  ```typescript
  // Instead of: {{'DESIGNER.EDITOR_PANEL.LABELS.CONTAINER' | exsTranslate}}
  // Use: {{ MSG.DESIGNER.EDITOR_PANEL.LABELS.CONTAINER }}
  // After: readonly MSG = MESSAGES;
  ```

- **Class bindings**: For small numbers of classes, use `[class.name]` syntax instead of `[ngClass]`.

- **Direct class application**: Don't pass inputs just for classes. Apply classes directly on component usage and style with `:host`:
  ```html
  <!-- Instead of: [hasLongValues]="true" -->
  <content-editor-input-property class="vertical"></content-editor-input-property>
  ```

- **Avoid ::ng-deep**: Breaks styling encapsulation. When necessary, always accompany with `:host-context` selector to prevent global leakage.

- **Enum access in templates**: If component template needs few enum members, attach just those values to component class itself.

### Performance

- **Avoid premature caching**: Don't cache state that can be easily rederived, especially from `DocBase.activeSelection` or active Widget class. Increases complexity and brittleness.

- **Deprecate bootstrap.css**: Don't use in newer components due to performance and reusability issues.

## Testing Best Practices

### General Testing

- **Never use sleep()**: Always use waits instead. Causes tests to be slower than necessary or fail flakily.

- **Wait only for async operations**: Selenium cannot interact during JS execution. Only wait for async tasks (AJAX, animations, saving). Synchronous actions don't require waits.

- **Implicit waits in mid-level framework**: Place waits in framework methods that initiate async actions, not in tests or low-level framework. Create dedicated `waitUntilSomething()` methods.

- **Abstract with framework classes**: Avoid working directly with WebElements. Use test framework classes that represent product portions:
  ```java
  // Use: page.cancelChangesButton.click()
  // Not: seleniumSession.getElement(By.id("cancelChanges")).click()
  // Better: page.cancelChanges()
  ```

- **Avoid Element class**: Use `SimpleElementWrapper` or extended classes instead. `Element` doesn't support passing down `SeleniumSession`.

- **Avoid global test base**: Don't use `getCurrentSeleniumSession()`, `AssertCondition.waitUntil()`, or other methods accessing global test base. Pass `SeleniumSession` through hierarchy.

- **Framework class design**: Use classes consuming `Supplier<SeleniumSession>`. No mutable state or static framework for UI. Extend `SimpleElementWrapper` or `SeleniumSessionSupplier`.

- **Minimize Selenium API calls**: Each call is expensive (network requests). Cache values and avoid redundant requests.

- **Scroll only when needed**: Only scroll if required by window size or scroll position. Never scroll to always-visible elements (e.g., modal dialog buttons).

- **Independent tests**: Tests must never depend on other tests passing or running. Don't use `dependsOn` or `priority` attributes for test ordering (only for efficiency).

- **Use keyboard interface**: Use `SeleniumSession.keyboard` instead of `WebElement.sendKeys()` for keyboard events (exception: file upload inputs).

- **Clean up resources**: Tests must clean up created resources. Use `RequiresExport` annotation with `undoAfter=true` for imports, or `addToDeletionQueue()` for other objects.

- **No unbounded loops**: All while/do-while loops must have counters that halt loop and/or fail test after iterations.

- **Headless when possible**: Mark test classes as headless via `TestBase.headless()` when headed browser not required. Headed needed for: copy/paste, file uploads.

- **Thread-safe framework**: All test and framework logic must be thread-safe for concurrent execution.

- **Wait for animations**: UI components must finish animating before interaction. Framework methods should wait using `waitUntilElementHasStartedThenStoppedMoving()` or `waitUntilElementHasFinishedScrolling()`.

### Test Patterns

- **Consumer<SomeDialog> pattern**: Primary pattern for dialog interaction. Method opening dialog:
  1. Opens dialog via click/keyboard
  2. Waits for animation (if applicable)
  3. Waits for server content (if applicable)
  4. Executes test logic passed in
  5. Asserts dialog closed (optional)
  
  Example:
  ```java
  public void openBulletPropsDialog(Consumer<BulletedListDialog> testCode) {
      this.buttons.toggleBulletDialog.click();
      testCode.accept(this.bulletedListDialog);
      if (this.bulletedListDialog.isOpen()) {
          this.getSeleniumSession().keyboard.esc();
      }
  }
  ```

### Debugging Flaky Tests

1. Reproduce locally: Run entire test class, use `invocationCount`, throttle network with `-Dchrome.speed.preset=Good3G`
2. Insert additional assertions to fail earlier
3. Identify failure location using sleeps/waits to isolate issue
4. Formulate solution:
   - If wait solves it: Either product has inherent async (expose via framework method) or product has errant async logic (product defect)
