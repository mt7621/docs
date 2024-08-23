import http from'k6/http';
import { htmlReport } from'https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js';
import { sleep } from'k6';

const numRecords = 50000;
const baseURL = 'http://dryzwgecjbml9.cloudfront.net/v1/employee';
let numValue=1


function getNameForRequest(iteration) {
  const requestNumber = (iteration % numRecords);
  return`dump${requestNumber}`;
}
export default function() {
  const iteration = __ITER;
  const nameValue = getNameForRequest(iteration);
  const url = `${baseURL}?first_name=${nameValue}&last_name=${nameValue}`;
  http.get(url);
  //const url = baseURL;
  numValue+=1;
  // let body = {"emp_no":numValue,"birth_date":"1957-05-02","first_name":"dbdump","last_name":"dbdump","gender":"M","hire_date":"1997-11-30"};
  //let body = {"length": 256};
  //http.post(url, JSON.stringify(body), {
  //  headers: { 'Content-Type': 'application/json' }
  //})

}

export const options = {
  vus: 1000,
  duration: '2m'
};

export function handleSummary(data) {
  return {
    "summary.html": htmlReport(data),
  };
}