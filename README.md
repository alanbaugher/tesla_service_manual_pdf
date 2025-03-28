# tesla_service_manual_pdf
Covert HTML layout using tds-layout and tds-list

# Monitor Changes
- https://service.tesla.com/docs/ModelX/ServiceManual/Palladium/en-us/GUID-58B67760-D8F5-4178-BA12-93ACE9831C0F.html


# Challenge:
- The Tesla site for the Model X User Manual provides a pdf download.
- https://www.tesla.com/ownersmanual/modelx/en_us/    
  
- The Tesla site for the Model X Service Manual is web access only (03/2025).   There is no associated PDF to download.
- https://service.tesla.com/docs/ModelX/ServiceManual/Palladium/en-us/index.html  
  

# Resolution
Used Chrome F12 elements to identify the side-link-tags used.
- Use ChatGPT to help build a container with the three (3) primary files [Dockerfile, package.json, index.js] contained as HEREDOC within a single bash shell script.
- ![image](https://github.com/user-attachments/assets/7223dc70-63f1-4ba9-bf60-324e72268f6c)
- Observation:  Each side-link-tag takes 4-5 seconds to resolve.
- Total duration: 1153 side-link-tags x 5s = 5765s  > 96 minutes to generate a recent PDF
  


![image](https://github.com/user-attachments/assets/989077c4-148a-4c2b-81a8-0e7f55c44426)


This document is large.  See below error

![image](https://github.com/user-attachments/assets/7899fd57-6208-4909-8647-9bbe725aa11f)
