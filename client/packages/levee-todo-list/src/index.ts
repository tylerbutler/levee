/**
 * Levee TodoList example - collaborative todo list using SharedTree.
 *
 * @packageDocumentation
 */

// Fluid setup
export {
	createTodoItem,
	initializeAppForNewContainer,
	loadAppFromExistingContainer,
	type TodoListContainerSchema,
	todoListContainerSchema,
} from "./fluid.js";
// Sandbag-compatible mount
export { type MountConfig, mount } from "./mount.js";

// Data model
export { TodoItem, TodoList } from "./schema.js";
