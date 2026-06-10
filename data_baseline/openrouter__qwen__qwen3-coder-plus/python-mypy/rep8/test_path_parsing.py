#!/usr/bin/env python3
"""
Simple test to verify path parsing logic.
"""

def debug_path_parsing():
    print("Testing path parsing logic:")
    
    # Test cases:
    paths_with_expected_ids = [
        ("/todos/1", 1),
        ("/todos/123", 123),
        ("/todos/999999", 999999),
        (None, None)  # Will test manually for other scenarios
    ]
    
    # Testing the extraction algorithm used in server
    for path, expected_id in paths_with_expected_ids[:3]:  # Skipping the manual ones
        path_parts = path.split('/')
        if len(path_parts) >= 3 and path_parts[1] == 'todos':
            todo_id_str = path_parts[2]  # Changed from [2:] to just [2]
            try:
                extracted_id = int(todo_id_str)
                print(f"Path: {path} -> extracted ID: {extracted_id}, Expected: {expected_id}, Match: {extracted_id == expected_id}")
            except ValueError:
                print(f"Path: {path} -> invalid ID string: {todo_id_str}")
        else:
            print(f"Path: {path} -> wrong format")


def debug_url_parsing_methods():
    print("\nChecking the pattern in handle methods:")
    print("""
    # Example pattern in _handle_get_todo():
    path_parts = self.path.split('/')
    if len(path_parts) != 3 or path_parts[1] != 'todos':
        self._send_error(404, 'Todo not found')
        return
    
    todo_id_str = path_parts[2]
    try:
        todo_id = int(todo_id_str)
    """)
    print("✓ All handle methods should use the same format")


if __name__ == '__main__':
    debug_path_parsing()
    debug_url_parsing_methods()