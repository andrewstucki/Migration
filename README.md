# Migration tool/service

## Setup

- Follow step 1 found here: https://developers.google.com/drive/v3/web/quickstart/ruby#prerequisites
- Make sure you have a file called client_secret.json in your current directory

## Running

To see how this works:

    bundle install && bundle exec ruby exporter.rb

This should create the following tree in your google drive, as seen in the mock.yml:

- Migration Test
  - __page1
    - _Attachments
      - __page1_at1
      - __page1_at2
    - __page1_sp1
    - __page1_doc1
    - ___page1
    - __page1_page1
      - _Attachments
      - __page1_page1_sp1    
      - __page1_page1_doc1    
      - __page1_page1_doc2    
      - ___page1_page1
  - __page2
    - _Attachments
    - __page2_sp1
    - __page2_sp2
    - ___page2
  - __sp1
