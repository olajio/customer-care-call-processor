#!/usr/bin/env python3
"""
Test Google Drive Service Account Access
Stage 1 - Step 1.6: Test Service Account Access
"""

import os
import sys

def check_dependencies():
    """Check if required packages are installed"""
    try:
        from google.oauth2 import service_account
        from googleapiclient.discovery import build
        print("✓ Required packages are installed\n")
        return True
    except ImportError:
        print("❌ Missing required packages!")
        print("\nPlease install them with:")
        print("  pip install google-auth google-auth-oauthlib google-auth-httplib2 google-api-python-client")
        return False

def test_service_account_access():
    """Test Google Drive service account access"""
    from google.oauth2 import service_account
    from googleapiclient.discovery import build
    from googleapiclient.errors import HttpError
    
    print("=" * 70)
    print("Google Drive Service Account Access Test")
    print("=" * 70)
    print()
    
    # Get service account JSON file path
    print("Step 1: Service Account JSON File")
    print("-" * 70)
    json_file = input("Enter the path to your service account JSON file: ").strip()
    
    # Handle relative paths and home directory
    json_file = os.path.expanduser(json_file)
    
    # Remove quotes if user pasted path with quotes
    json_file = json_file.strip("'\"")
    
    if not os.path.exists(json_file):
        print(f"\n❌ Error: File not found at '{json_file}'")
        print("\nTip: You can drag and drop the file into the terminal to get the full path")
        return False
    
    print(f"✓ Found JSON file: {json_file}\n")
    
    # Get folder ID
    print("Step 2: Google Drive Folder ID")
    print("-" * 70)
    print("The folder ID is in the URL when you open the folder in Google Drive:")
    print("https://drive.google.com/drive/folders/YOUR_FOLDER_ID_HERE")
    print()
    folder_id = input("Enter your Google Drive folder ID: ").strip()
    
    if not folder_id:
        print("\n❌ Error: Folder ID cannot be empty")
        return False
    
    print(f"✓ Folder ID: {folder_id}\n")
    
    # Authenticate
    print("Step 3: Authenticating with Google Drive")
    print("-" * 70)
    try:
        credentials = service_account.Credentials.from_service_account_file(
            json_file,
            scopes=['https://www.googleapis.com/auth/drive.readonly']
        )
        print("✓ Successfully loaded credentials")
        print(f"✓ Service account email: {credentials.service_account_email}\n")
    except Exception as e:
        print(f"❌ Error loading credentials: {e}")
        return False
    
    # Build Drive API client
    print("Step 4: Connecting to Google Drive API")
    print("-" * 70)
    try:
        service = build('drive', 'v3', credentials=credentials)
        print("✓ Successfully connected to Google Drive API\n")
    except Exception as e:
        print(f"❌ Error connecting to API: {e}")
        return False
    
    # List files in folder
    print("Step 5: Testing Folder Access")
    print("-" * 70)
    try:
        results = service.files().list(
            q=f"'{folder_id}' in parents and trashed=false",
            pageSize=10,
            fields="files(id, name, mimeType, size, createdTime, modifiedTime)",
            supportsAllDrives=True,
            includeItemsFromAllDrives=True
        ).execute()
        
        files = results.get('files', [])
        
        print(f"✓ Successfully accessed folder!")
        print(f"✓ Found {len(files)} file(s) in the folder\n")
        
        if files:
            print("Files in folder:")
            print("-" * 70)
            for i, file in enumerate(files, 1):
                print(f"\n{i}. {file['name']}")
                print(f"   ID: {file['id']}")
                print(f"   Type: {file['mimeType']}")
                if 'size' in file:
                    size_mb = int(file['size']) / (1024 * 1024)
                    print(f"   Size: {size_mb:.2f} MB")
                print(f"   Created: {file.get('createdTime', 'N/A')}")
        else:
            print("ℹ️  No files found in folder (folder is empty)")
            print("   This is normal if you haven't uploaded any files yet")
        
        print("\n" + "=" * 70)
        print("✅ SUCCESS! Service account can access Google Drive folder")
        print("=" * 70)
        print("\n📝 Save these values for later stages:")
        print(f"   Service Account Email: {credentials.service_account_email}")
        print(f"   Folder ID: {folder_id}")
        print(f"   JSON File Path: {json_file}")
        print("\nYou can now proceed to Stage 2: AWS Account and Foundation Setup")
        print("Mark Stage 1 as complete in 03_stage_completion_checklist.md")
        
        return True
        
    except HttpError as e:
        print(f"❌ Error accessing folder: {e}")
        print("\nPossible issues:")
        print("  1. Folder ID is incorrect")
        print("  2. Service account doesn't have access to this folder")
        print("  3. Folder was deleted or moved")
        print("\nTo fix:")
        print("  1. Verify the folder ID from the Google Drive URL")
        print("  2. Share the folder with the service account email:")
        print(f"     {credentials.service_account_email}")
        print("  3. Grant 'Viewer' permission")
        return False
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        return False

def main():
    print("\n")
    
    # Check dependencies
    if not check_dependencies():
        sys.exit(1)
    
    # Test access
    success = test_service_account_access()
    
    print("\n")
    
    if success:
        sys.exit(0)
    else:
        sys.exit(1)

if __name__ == '__main__':
    main()
